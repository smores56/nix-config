#!/usr/bin/env python3
"""Generic rclone 3-2-1 backup for a single dataset.

One copy of the data lives in a versioned local mirror (copy #2) on the backup
disk, and — when the dataset is offsite — a second copy mirrors that mirror to
Proton Drive (copy #3). The source itself is copy #1.

Nothing here ever deletes source data:

* Every transport uses `rclone copy`, never `sync`. `sync` would propagate a
  local deletion into the mirror; `copy` only ever adds or overwrites.
* The local copy is versioned with `--backup-dir`: when a file changes, rclone
  moves the previous revision under `versions/<date>` instead of clobbering it,
  so overwritten and deleted files survive locally.
* The offsite copy deliberately has no `--backup-dir`: versions stay local-only.
  The remote is a plain append-only mirror — stale files there are harmless and
  are never pruned, so a lost local disk cannot take the offsite copy with it.

The offsite copy is verified with `rclone check --checksum`. rclone exits 0 even
when it could not actually compare anything (e.g. a hash-less backend), so the
"<n> hashes could not be checked" summary is parsed and any non-zero count is a
hard failure: an unverified mirror is not a backup.

Every rclone step is watched for stalled progress: a transfer that stops
advancing is killed and retried (the copy is resumable). rclone's own idle
timeout does not catch a wedged upload session, which once hung a seed run for
18h while it held the shared Proton lock.

The rclone config (holding the Proton credential) is read from a file at
runtime, never passed on the command line (argv leaks to `ps`) and never baked
into the Nix store.
"""

import argparse
import datetime
import fcntl
import os
import re
import select
import shlex
import subprocess
import sys
import time
from collections import namedtuple

# Host-wide run lock shared by every entry point (systemd timer, manual
# `backup`, seed runs). Serializing here stops two rclone clients blanking the
# single-use Proton refresh token (rclone#9880). Created 0600 in /run/lock.
LOCK_PATH = "/run/lock/media-backup.lock"
# rclone logs a stats block this often (see STATS_FLAGS); the stall watchdog can
# only observe progress at this cadence, so a shorter window would kill healthy
# transfers between ticks.
STATS_INTERVAL = 30
# Wall-clock cap for a non-rclone step (e.g. the preBackup pg_dump) when the
# dataset sets none. Unlike the stall watchdog this is ALWAYS applied, so
# stall-timeout 0 cannot leave a hung dump holding the lock forever.
DEFAULT_STEP_TIMEOUT = 12 * 3600
# Bound the partial-line buffer: a stream that never sends a newline (e.g. a
# wedged binary transfer) must not grow memory without limit.
_MAX_PARTIAL_LINE = 1 << 20

Dataset = namedtuple(
    "Dataset",
    [
        "name",  # dataset name, also the folder name on the remote
        "source",  # directory being backed up
        "backup_root",  # mount point of the backup disk
        "offsite",  # whether to mirror to the remote
        "remote",  # rclone remote name, e.g. "proton"
        "rclone_config",  # rclone config holding the remote (mode 0600, root)
        "pre_backup",  # optional shell snippet run before the copy
        "stall_timeout",  # seconds of no transfer progress before aborting a step
        "excludes",  # rclone exclude patterns (secrets, regenerable caches)
        "timeout",  # wall-clock cap on non-rclone steps (preBackup)
    ],
    defaults=(0, (), DEFAULT_STEP_TIMEOUT),
)

_UNCHECKED_RE = re.compile(r"(\d+) hashes could not be checked")

# The multi-line stats block carries these counters on their own lines, e.g.
# "Transferred:   \t1.234 GiB / 5.678 GiB, 22%, 10.1 MiB/s, ETA 5m2s" and
# "Checks:                 12 / 40,  30%". Do NOT use --stats-one-line: it drops
# the "Transferred:"/"Checks:" labels and leaves only "<size> / <total>, ...".
_TRANSFERRED_RE = re.compile(r"Transferred:\s+([\d.]+)\s*([KMGTP]?)i?B", re.I)
_CHECKS_RE = re.compile(r"Checks:\s+(\d+)")
_SIZE_UNITS = {"": 1, "K": 1024, "M": 1024**2, "G": 1024**3, "T": 1024**4, "P": 1024**5}
# C0 control characters except tab: rclone relays source filenames verbatim, so
# a crafted name can smuggle ANSI escapes into the journal or the failure marker.
_CONTROL_RE = re.compile(r"[\x00-\x08\x0a-\x1f]")

# Proton Drive answers transient 404/422/502s under load. These make rclone back
# off and retry them instead of surfacing a failure, and cap how long any single
# connection may sit idle.
NETWORK_FLAGS = [
    "--timeout",
    "5m",
    "--contimeout",
    "30s",
    "--retries",
    "5",
    "--low-level-retries",
    "20",
    "--retries-sleep",
    "10s",
]
# The stall watchdog reads the stats counters, which rclone logs at INFO — hidden
# by the default NOTICE level — so raise the stats-log level explicitly. The
# multi-line block (not --stats-one-line) is what keeps the counter labels.
STATS_FLAGS = ["--stats", f"{STATS_INTERVAL}s", "--stats-log-level", "NOTICE"]


class BackupError(Exception):
    """The backup ran but is not trustworthy (e.g. nothing was verified)."""


class StalledError(BackupError):
    """A step made no transfer progress for too long and was killed."""


def transferred_bytes(line):
    """Bytes transferred as reported by an rclone stats line, or None."""
    match = _TRANSFERRED_RE.search(line)
    if not match:
        return None
    return int(float(match.group(1)) * _SIZE_UNITS[match.group(2).upper()])


def checked_count(line):
    """Files checked/hashed so far as reported by rclone, or None.

    A pure `rclone check` transfers no bytes but still advances this counter, so
    without it a healthy long verification would look like a stall.
    """
    match = _CHECKS_RE.search(line)
    return int(match.group(1)) if match else None


class Progress:
    """Decide whether an rclone run has stopped making progress.

    rclone's own --timeout does not catch a wedged upload: a dead upload session
    keeps printing stats without tripping the IO idle timer, which once left a
    seed run hung for 18h holding the shared lock. A stalled run keeps emitting
    stats whose counters do not advance, so only a new high-water mark on either
    transferred bytes or checked files counts as progress.
    """

    def __init__(self, stall_timeout, clock=time.monotonic):
        self.stall_timeout = stall_timeout
        self._clock = clock
        self._last = clock()
        self._bytes = -1
        self._checks = -1

    def note(self, line):
        advanced = self._advance(line)
        if advanced:
            self._last = self._clock()

    def _advance(self, line):
        advanced = False
        current = transferred_bytes(line)
        if current is not None and current > self._bytes:
            self._bytes = current
            advanced = True
        checked = checked_count(line)
        if checked is not None and checked > self._checks:
            self._checks = checked
            advanced = True
        return advanced

    def stalled(self):
        return self._clock() - self._last > self.stall_timeout


def local_dir(cfg):
    return os.path.join(cfg.backup_root, cfg.name, "current")


def versions_dir(cfg, date):
    return os.path.join(cfg.backup_root, cfg.name, "versions", date)


def marker_path(cfg):
    return os.path.join(cfg.backup_root, cfg.name, "BACKUP-FAILED")


def _exclude_flags(cfg):
    """rclone --exclude flags, shared by both copies and the check.

    Excluded files never enter the mirror, so the offsite copy and the check
    must apply the same patterns or the check would flag them as missing.
    """
    flags = []
    for pattern in cfg.excludes:
        flags += ["--exclude", pattern]
    return flags


def _rclone_flags():
    """Global flags handed to every rclone invocation."""
    return [*NETWORK_FLAGS, *STATS_FLAGS]


def build_steps(cfg, date):
    """Return the argv list to run, in order. Pure; no side effects."""
    steps = []
    if cfg.pre_backup:
        # An executable script path, not a shell string: a multi-line snippet
        # cannot be a single systemd ExecStart argument (newlines end the
        # directive) and would stop the unit from loading.
        steps.append([cfg.pre_backup])
    # `copy`, never `sync`: the versioned local mirror must never lose data.
    steps.append(
        [
            "rclone",
            "--config",
            cfg.rclone_config,
            *_rclone_flags(),
            "copy",
            cfg.source,
            local_dir(cfg),
            "--backup-dir",
            versions_dir(cfg, date),
            *_exclude_flags(cfg),
        ]
    )
    if cfg.offsite:
        steps.append(
            [
                "rclone",
                "--config",
                cfg.rclone_config,
                *_rclone_flags(),
                # A failed Proton upload leaves a draft; without this the retry
                # dies with "a draft exist" and the file never reaches the mirror.
                "--protondrive-replace-existing-draft=true",
                "copy",
                local_dir(cfg),
                f"{cfg.remote}:{cfg.name}",
                *_exclude_flags(cfg),
            ]
        )
    return steps


def build_check(cfg):
    """Verify the offsite mirror by checksum; None when there is no offsite copy.

    `--one-way` is required: the remote is append-only, so it can legitimately
    hold files the mirror no longer does. A two-way check would treat those
    harmless extras as differences and wedge the dataset red forever.
    """
    if not cfg.offsite:
        return None
    return [
        "rclone",
        "--config",
        cfg.rclone_config,
        *_rclone_flags(),
        "check",
        "--checksum",
        "--one-way",
        local_dir(cfg),
        f"{cfg.remote}:{cfg.name}",
        *_exclude_flags(cfg),
    ]


def unchecked_hashes(output):
    """Count files rclone could not compare; 0 when no summary line is present."""
    match = _UNCHECKED_RE.search(output or "")
    return int(match.group(1)) if match else 0


def require_source(cfg):
    """Refuse to run when the source is missing or empty.

    `copy` never deletes, so an empty source would leave the mirror empty and
    `--one-way` would then pass trivially: a silent "backup succeeded" with
    nothing in it. A precondition failure here is a real failure.
    """
    if not os.path.isdir(cfg.source):
        raise BackupError(f"source {cfg.source!r} is not a directory")
    if not os.listdir(cfg.source):
        raise BackupError(f"source {cfg.source!r} is empty; refusing to back up nothing")


def resolve_date(cfg, date, now=None):
    """Pick the version folder: the date, or a date+time when one already exists.

    rclone's `--backup-dir` would otherwise overwrite a same-named file left by
    an earlier run on the same day, silently dropping that version.
    """
    if not os.path.exists(versions_dir(cfg, date)):
        return date
    stamp = (now or datetime.datetime.now()).strftime("%H%M%S")
    candidate = f"{date}T{stamp}"
    # Two runs can land in the same second; keep probing so the second run never
    # reuses (and so clobbers) the revision the first one just wrote. The host
    # lock serializes runs, so probing cannot race another resolve_date.
    serial = 1
    while os.path.exists(versions_dir(cfg, candidate)):
        candidate = f"{date}T{stamp}-{serial}"
        serial += 1
    return candidate


_SAFE_DATE_RE = re.compile(r"[A-Za-z0-9_.-]+")
_SAFE_NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")


def validate_date(date):
    """Reject a --date that could escape backup_root through --backup-dir.

    The date becomes a path component under `versions/`; anything carrying a
    path separator or a `..` could write outside the backup disk.
    """
    if not date or not _SAFE_DATE_RE.fullmatch(date) or ".." in date or date == ".":
        raise BackupError(
            f"invalid --date {date!r}: must be a plain date/timestamp token "
            "(letters, digits, dot, dash, underscore only; no path separators)"
        )
    return date


def validate_name(name):
    """Reject a --name that could escape the dataset directories.

    The name is used both as a local path component (`<backup_root>/<name>`) and
    as the remote folder (`<remote>:<name>`), so an empty, `.`/`..` or
    separator-bearing value could write outside the backup tree or address
    another remote path.
    """
    if (
        not name
        or not _SAFE_NAME_RE.fullmatch(name)
        or ".." in name
        or name == "."
    ):
        raise BackupError(
            f"invalid --name {name!r}: must start with a letter or digit and "
            "contain only letters, digits, dot, dash, underscore "
            "(no path separators)"
        )
    return name


def validate_stall_timeout(stall_timeout):
    """Reject a watchdog window the stats cadence cannot feed.

    Stats land every STATS_INTERVAL seconds, so a window shorter than two
    intervals can elapse between ticks and kill a healthy transfer. `0` disables
    the watchdog and is always valid.
    """
    minimum = 2 * STATS_INTERVAL
    if stall_timeout != 0 and stall_timeout < minimum:
        raise BackupError(
            f"stall-timeout {stall_timeout}s is below twice the rclone stats "
            f"interval ({minimum}s); pass 0 to disable the watchdog"
        )
    return stall_timeout


def acquire_lock(path=LOCK_PATH, out=None):
    """Block until an exclusive host-wide run lock is held; return its handle.

    Every entry point funnels through here so concurrent runs (timer, manual
    `backup`, seed) cannot blank the single-use Proton refresh token. The file
    is created 0600; closing the returned handle releases the lock.
    """
    out = out or (lambda line: print(line, file=sys.stderr))
    fd = os.open(path, os.O_CREAT | os.O_WRONLY, 0o600)
    handle = os.fdopen(fd, "w")
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        # Busy: say so (a silent multi-hour block is indistinguishable from a
        # hang) and then wait for the holder to finish.
        out(f"waiting for lock {path} ...")
        fcntl.flock(handle, fcntl.LOCK_EX)
    return handle


def quote(argv):
    return " ".join(shlex.quote(part) for part in argv)


def sanitize_output(text):
    """Strip C0 control characters (except tab) from raw rclone output.

    rclone relays source filenames verbatim, so an attacker-controlled name can
    inject ANSI escapes into the journal or the failure marker. The progress
    parser still receives the raw line; only what we print/persist is scrubbed.
    """
    return _CONTROL_RE.sub("", text)


def _sanitized(out):
    """Wrap `out` so it never relays raw control characters."""
    return lambda line: out(sanitize_output(line))


def parse_duration(text):
    """Parse a compact duration ("90", "30m", "2h", "1d") into seconds."""
    match = re.fullmatch(r"\s*(\d+)\s*([smhd]?)\s*", text or "")
    if not match:
        raise ValueError(f"not a duration: {text!r}")
    return int(match.group(1)) * {"": 1, "s": 1, "m": 60, "h": 3600, "d": 86400}[
        match.group(2)
    ]


def _plain_run(argv, capture=False, env=None, timeout=0):
    """Run a non-rclone step (e.g. the preBackup script); inherit stdio.

    A hung pg_dump would hold the host lock just like a hung rclone, so it is
    always bounded by a wall-clock timeout — independent of the stall watchdog,
    which can be switched off with stall-timeout 0.
    """
    limit = timeout or None
    if capture:
        result = subprocess.run(
            argv, capture_output=True, text=True, env=env, timeout=limit
        )
        if result.returncode != 0:
            raise subprocess.CalledProcessError(
                result.returncode, argv, result.stdout, result.stderr
            )
        return (result.stdout or "") + (result.stderr or "")
    subprocess.run(argv, check=True, text=True, env=env, timeout=limit)
    return ""


def run_streaming(
    argv,
    env=None,
    stall_timeout=0,
    attempts=1,
    popen=subprocess.Popen,
    ready=select.select,
    read=os.read,
    clock=time.monotonic,
    out=None,
    interval=None,
    capture=False,
):
    """Run argv, relaying output, and abort a step that stops making progress.

    The pipe is read in non-blocking chunks so a partial line cannot park the
    loop past the stall check (select only promises *some* bytes are ready). A
    stalled run is retried up to `attempts` times — `copy` is resumable — and a
    non-positive stall_timeout disables the watchdog and runs exactly once.
    """
    out = _sanitized(out or (lambda line: print(line, file=sys.stderr)))
    tries = attempts if stall_timeout > 0 else 1
    if interval is None:
        interval = min(30, stall_timeout / 2) if stall_timeout > 0 else 30
    for attempt in range(1, tries + 1):
        progress = Progress(stall_timeout, clock) if stall_timeout > 0 else None
        proc = popen(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
        stream = proc.stdout
        try:
            fd = stream.fileno()
        except (AttributeError, OSError, ValueError):
            fd = stream
        lines = []
        pending = b""
        stalled = False
        try:
            while True:
                if progress is not None and not ready([fd], [], [], interval)[0]:
                    if progress.stalled():
                        stalled = True
                        break
                    continue
                chunk = read(fd, 65536)
                if chunk == b"":
                    break
                pending += chunk
                while b"\n" in pending:
                    raw, pending = pending.split(b"\n", 1)
                    line = raw.decode("utf-8", "replace").rstrip("\r")
                    out(line)
                    lines.append(line)
                    if progress is not None:
                        # Sample every line: the failure mode keeps printing
                        # stats, so checking only on silence would miss it.
                        progress.note(line)
                if len(pending) > _MAX_PARTIAL_LINE:
                    # A newline-free stream must not grow the buffer without
                    # limit; flush it as a line (it carries no stats counters).
                    line = pending.decode("utf-8", "replace").rstrip("\r")
                    out(line)
                    lines.append(line)
                    pending = b""
                if progress is not None and progress.stalled():
                    # Check after EVERY read, not only on silence or a newline:
                    # a stream that keeps delivering bytes without newlines must
                    # still be watched for a stall.
                    stalled = True
                    break
            if pending and not stalled:
                line = pending.decode("utf-8", "replace").rstrip("\r")
                out(line)
                lines.append(line)
        finally:
            if stalled:
                proc.kill()
            proc.wait()
            stream.close()
        if stalled:
            if attempt < tries:
                out(f"! stalled, retry {attempt}/{tries - 1}: {quote(argv)}")
                continue
            raise StalledError(
                f"no transfer progress for {stall_timeout}s: {quote(argv)}"
            )
        if proc.returncode != 0:
            raise subprocess.CalledProcessError(proc.returncode, argv, "\n".join(lines))
        return "\n".join(lines) if capture else ""


def make_runner(stall_timeout, attempts=3, out=None, plain_timeout=DEFAULT_STEP_TIMEOUT):
    """Default step runner: rclone steps get the stall watchdog, others do not.

    A non-rclone step (the preBackup dump) is still bounded by a wall-clock
    timeout independent of the stall setting: a hung pg_dump must be killed even
    when the watchdog is disabled with stall-timeout 0, or it would hold the
    host lock forever.
    """

    def run(argv, capture=False, env=None):
        if os.path.basename(argv[0]) != "rclone":
            return _plain_run(argv, capture=capture, env=env, timeout=plain_timeout)
        return run_streaming(
            argv,
            env=env,
            stall_timeout=stall_timeout,
            attempts=attempts,
            out=out,
            capture=capture,
        )

    return run


def _pre_backup_env(cfg, date):
    return {
        **os.environ,
        "BACKUP_DATE": date,
        "BACKUP_CURRENT": local_dir(cfg),
        "BACKUP_SOURCE": cfg.source,
    }


def run_backup(cfg, date, dry_run=False, run=None, out=print, lock=True):
    run = run or make_runner(
        cfg.stall_timeout, plain_timeout=cfg.timeout or DEFAULT_STEP_TIMEOUT
    )
    # Hold the host lock for the whole run (all entry points funnel through
    # here), except for a dry run which touches nothing.
    lock_handle = acquire_lock(out=out) if (lock and not dry_run) else None
    try:
        if not dry_run:
            require_source(cfg)
            os.makedirs(local_dir(cfg), mode=0o700, exist_ok=True)
            # Resolve before creating, so an existing same-day folder is detected.
            date = resolve_date(cfg, date)
            os.makedirs(versions_dir(cfg, date), mode=0o700, exist_ok=True)

        pre_step = [cfg.pre_backup] if cfg.pre_backup else None
        for step in build_steps(cfg, date):
            out("+ " + quote(step))
            if dry_run:
                continue
            if pre_step is not None and step == pre_step:
                run(step, env=_pre_backup_env(cfg, date))
            else:
                run(step)

        check = build_check(cfg)
        if check is not None:
            out("+ " + quote(check))
            if not dry_run:
                result = run(check, capture=True)
                # run_streaming returns the captured output; the summary may land
                # on either stream depending on rclone version.
                output = result or ""
                if unchecked_hashes(output) > 0:
                    raise BackupError(
                        f"offsite check could not verify every file: {output.strip()}"
                    )
                if checked_count(output) == 0:
                    raise BackupError(
                        "offsite check verified no files; the mirror may be empty "
                        "(over-broad excludes?)"
                    )
        if not dry_run and os.path.exists(marker_path(cfg)):
            # Remove inside the lock so a concurrent run cannot interleave
            # between the success and the marker cleanup.
            os.remove(marker_path(cfg))
    except Exception as error:
        if not dry_run:
            try:
                # require_source can fail before any makedirs, so the dataset dir
                # may not exist yet; create it so the marker can be written.
                os.makedirs(
                    os.path.dirname(marker_path(cfg)), mode=0o700, exist_ok=True
                )
                with open(marker_path(cfg), "w") as handle:
                    message = f"{type(error).__name__}: {error}"
                    handle.write(sanitize_output(message) + "\n")
            except OSError:
                # The marker is best-effort: never let writing it raise over
                # (and mask) the original failure.
                pass
        raise
    finally:
        if lock_handle is not None:
            lock_handle.close()  # releases the flock
    out("backup complete")


def main(argv=None):
    parser = argparse.ArgumentParser(prog="backup", description=__doc__)
    parser.add_argument("--name", required=True, help="dataset name / remote folder")
    parser.add_argument("--source", required=True, help="directory to back up")
    parser.add_argument("--backup-root", required=True, help="backup disk mount point")
    parser.add_argument("--remote", default="proton", help="rclone remote name")
    parser.add_argument("--rclone-config", required=True, help="rclone config path")
    parser.add_argument("--offsite", action="store_true", help="mirror to the remote")
    parser.add_argument("--pre-backup", default=None, help="executable run first")
    parser.add_argument(
        "--exclude",
        action="append",
        default=[],
        help="rclone exclude pattern (repeatable)",
    )
    parser.add_argument(
        "--stall-timeout",
        default="30m",
        help="abort a step with no transfer progress for this long and retry it",
    )
    parser.add_argument(
        "--timeout",
        default="12h",
        help="wall-clock cap on non-rclone steps (e.g. preBackup); always applied",
    )
    parser.add_argument(
        "--date",
        default=datetime.date.today().isoformat(),
        help="version folder name for this run",
    )
    parser.add_argument("--dry-run", action="store_true", help="print steps only")
    parser.add_argument(
        "--no-lock",
        action="store_true",
        help="skip the host-wide run lock; only honored when "
        "BACKUP_ALLOW_NO_LOCK=1 (tests only)",
    )
    args = parser.parse_args(argv)

    try:
        if args.no_lock and os.environ.get("BACKUP_ALLOW_NO_LOCK") != "1":
            raise BackupError(
                "--no-lock requires BACKUP_ALLOW_NO_LOCK=1: bypassing the "
                "host-wide lock risks two rclone clients blanking the "
                "single-use Proton token"
            )
        cfg = Dataset(
            name=validate_name(args.name),
            source=args.source,
            backup_root=args.backup_root,
            offsite=args.offsite,
            remote=args.remote,
            rclone_config=args.rclone_config,
            pre_backup=args.pre_backup,
            stall_timeout=validate_stall_timeout(parse_duration(args.stall_timeout)),
            excludes=tuple(args.exclude),
            timeout=parse_duration(args.timeout),
        )
        run_backup(
            cfg,
            validate_date(args.date),
            dry_run=args.dry_run,
            lock=not args.no_lock,
        )
    except Exception as error:  # noqa: BLE001 - top-level CLI boundary
        print(f"backup failed: {sanitize_output(str(error))}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
