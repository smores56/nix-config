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

The rclone config (holding the Proton credential) is read from a file at
runtime, never passed on the command line (argv leaks to `ps`) and never baked
into the Nix store.
"""

import argparse
import datetime
import os
import re
import shlex
import subprocess
import sys
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
    ],
)

_UNCHECKED_RE = re.compile(r"(\d+) hashes could not be checked")


class BackupError(Exception):
    """The backup ran but is not trustworthy (e.g. nothing was verified)."""


def local_dir(cfg):
    return os.path.join(cfg.backup_root, cfg.name, "current")


def versions_dir(cfg, date):
    return os.path.join(cfg.backup_root, cfg.name, "versions", date)


def marker_path(cfg):
    return os.path.join(cfg.backup_root, cfg.name, "BACKUP-FAILED")


def build_steps(cfg, date):
    """Return the argv list to run, in order. Pure; no side effects."""
    steps = []
    if cfg.pre_backup:
        steps.append(["sh", "-c", cfg.pre_backup])
    # `copy`, never `sync`: the versioned local mirror must never lose data.
    steps.append(
        [
            "rclone",
            "--config",
            cfg.rclone_config,
            "copy",
            cfg.source,
            local_dir(cfg),
            "--backup-dir",
            versions_dir(cfg, date),
        ]
    )
    if cfg.offsite:
        steps.append(
            [
                "rclone",
                "--config",
                cfg.rclone_config,
                # A failed Proton upload leaves a draft; without this the retry
                # dies with "a draft exist" and the file never reaches the mirror.
                "--protondrive-replace-existing-draft=true",
                "copy",
                local_dir(cfg),
                f"{cfg.remote}:{cfg.name}",
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
        "check",
        "--checksum",
        "--one-way",
        local_dir(cfg),
        f"{cfg.remote}:{cfg.name}",
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


def _run(argv, capture=False, env=None):
    return subprocess.run(argv, check=True, capture_output=capture, text=True, env=env)


def _pre_backup_env(cfg, date):
    return {
        **os.environ,
        "BACKUP_DATE": date,
        "BACKUP_CURRENT": local_dir(cfg),
        "BACKUP_SOURCE": cfg.source,
    }


def run_backup(cfg, date, dry_run=False, run=_run, out=print):
    try:
        if not dry_run:
            require_source(cfg)
            os.makedirs(local_dir(cfg), mode=0o700, exist_ok=True)
            # Resolve before creating, so an existing same-day folder is detected.
            date = resolve_date(cfg, date)
            os.makedirs(versions_dir(cfg, date), mode=0o700, exist_ok=True)

        for step in build_steps(cfg, date):
            out("+ " + quote(step))
            if dry_run:
                continue
            if cfg.pre_backup and step[0] == "sh":
                run(step, env=_pre_backup_env(cfg, date))
            else:
                run(step)

        check = build_check(cfg)
        if check is not None:
            out("+ " + quote(check))
            if not dry_run:
                result = run(check, capture=True)
                # rclone logs the "hashes could not be checked" summary on either
                # stream depending on version; a fake result may expose only stdout.
                output = (getattr(result, "stdout", "") or "") + (
                    getattr(result, "stderr", "") or ""
                )
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
    parser.add_argument("--pre-backup", default=None, help="shell snippet run first")
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
    )
    try:
        run_backup(cfg, args.date, dry_run=args.dry_run)
    except Exception as error:  # noqa: BLE001 - top-level CLI boundary
        print(f"backup failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
