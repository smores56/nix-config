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
import os
import re
import select
import shlex
import subprocess
import sys
import time
from collections import namedtuple

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
    ],
    defaults=(0, ()),
)

_UNCHECKED_RE = re.compile(r"(\d+) hashes could not be checked")

# rclone prints one stats line per --stats interval, e.g.
# "Transferred:   1.234 GiB / 5.678 GiB, 22%, 10.1 MiB/s, ETA 5m2s".
_TRANSFERRED_RE = re.compile(r"Transferred:\s+([\d.]+)\s*([KMGTP]?)i?B", re.I)
_SIZE_UNITS = {"": 1, "K": 1024, "M": 1024**2, "G": 1024**3, "T": 1024**4, "P": 1024**5}

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
# The stall watchdog reads the transferred-byte field, so ask for machine-readable
# progress. rclone emits it regardless of verbosity, straight into the journal.
STATS_FLAGS = ["--stats", "30s", "--stats-one-line"]


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


class Progress:
    """Decide whether an rclone run has stopped making progress.

    rclone's own --timeout does not catch a wedged upload: a dead upload session
    keeps printing stats without tripping the IO idle timer, which once left a
    seed run hung for 18h holding the shared lock. A stalled run keeps emitting
    stats lines whose transferred-byte count does not advance, so only a new
    high-water mark counts as progress.
    """

    def __init__(self, stall_timeout, clock=time.monotonic):
        self.stall_timeout = stall_timeout
        self._clock = clock
        self._last = clock()
        self._bytes = -1

    def note(self, line):
        current = transferred_bytes(line)
        if current is not None and current > self._bytes:
            self._bytes = current
            self._last = self._clock()

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
    return f"{date}T{stamp}"


def quote(argv):
    return " ".join(shlex.quote(part) for part in argv)


def parse_duration(text):
    """Parse a compact duration ("90", "30m", "2h", "1d") into seconds."""
    match = re.fullmatch(r"\s*(\d+)\s*([smhd]?)\s*", text or "")
    if not match:
        raise ValueError(f"not a duration: {text!r}")
    return int(match.group(1)) * {"": 1, "s": 1, "m": 60, "h": 3600, "d": 86400}[
        match.group(2)
    ]


def _plain_run(argv, capture=False, env=None):
    """Run a non-rclone step (e.g. the preBackup script); inherit stdio."""
    if capture:
        result = subprocess.run(argv, capture_output=True, text=True, env=env)
        if result.returncode != 0:
            raise subprocess.CalledProcessError(
                result.returncode, argv, result.stdout, result.stderr
            )
        return (result.stdout or "") + (result.stderr or "")
    subprocess.run(argv, check=True, text=True, env=env)
    return ""


def run_streaming(
    argv,
    env=None,
    stall_timeout=0,
    attempts=1,
    popen=subprocess.Popen,
    ready=select.select,
    clock=time.monotonic,
    out=None,
    interval=30,
):
    """Run argv, relaying output, and abort a step that stops transferring.

    `copy` is resumable, so a stalled run is retried up to `attempts` times. A
    non-positive stall_timeout disables the watchdog and runs once.
    """
    out = out or (lambda line: print(line, file=sys.stderr))
    tries = attempts if stall_timeout > 0 else 1
    for attempt in range(1, tries + 1):
        progress = Progress(stall_timeout, clock) if stall_timeout > 0 else None
        proc = popen(
            argv,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            env=env,
            bufsize=1,
        )
        lines = []
        try:
            while True:
                if progress is not None and not ready([proc.stdout], [], [], interval)[0]:
                    if progress.stalled():
                        proc.kill()
                        proc.wait()
                        raise StalledError(
                            f"no transfer progress for {stall_timeout}s: {quote(argv)}"
                        )
                    continue
                line = proc.stdout.readline()
                if line == "":
                    break
                line = line.rstrip("\n")
                out(line)
                lines.append(line)
                if progress is not None:
                    progress.note(line)
            code = proc.wait()
        except StalledError:
            if attempt < tries:
                out(f"! stalled, retry {attempt}/{tries - 1}: {quote(argv)}")
                continue
            raise
        if code != 0:
            raise subprocess.CalledProcessError(code, argv, "\n".join(lines))
        return "\n".join(lines)


def make_runner(stall_timeout, attempts=3, out=None):
    """Default step runner: rclone steps get the stall watchdog, others do not."""

    def run(argv, capture=False, env=None):
        if os.path.basename(argv[0]) != "rclone":
            return _plain_run(argv, capture=capture, env=env)
        return run_streaming(
            argv, env=env, stall_timeout=stall_timeout, attempts=attempts, out=out
        )

    return run


def _pre_backup_env(cfg, date):
    return {
        **os.environ,
        "BACKUP_DATE": date,
        "BACKUP_CURRENT": local_dir(cfg),
        "BACKUP_SOURCE": cfg.source,
    }


def run_backup(cfg, date, dry_run=False, run=None, out=print):
    run = run or make_runner(cfg.stall_timeout)
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
    except Exception as error:
        if not dry_run:
            with open(marker_path(cfg), "w") as handle:
                handle.write(f"{type(error).__name__}: {error}\n")
        raise

    if not dry_run and os.path.exists(marker_path(cfg)):
        os.remove(marker_path(cfg))
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
        "--date",
        default=datetime.date.today().isoformat(),
        help="version folder name for this run",
    )
    parser.add_argument("--dry-run", action="store_true", help="print steps only")
    args = parser.parse_args(argv)

    cfg = Dataset(
        name=args.name,
        source=args.source,
        backup_root=args.backup_root,
        offsite=args.offsite,
        remote=args.remote,
        rclone_config=args.rclone_config,
        pre_backup=args.pre_backup,
        stall_timeout=parse_duration(args.stall_timeout),
        excludes=tuple(args.exclude),
    )
    try:
        run_backup(cfg, args.date, dry_run=args.dry_run)
    except Exception as error:  # noqa: BLE001 - top-level CLI boundary
        print(f"backup failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
