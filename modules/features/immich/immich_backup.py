#!/usr/bin/env python3
"""Daily Immich backup: pg_dump + restic snapshot onto the backup disk, then an
append-only rclone copy of the restic repo to Proton Drive.

Two independent copies exist, and neither destroys the other:

* The backup disk holds dated restic snapshots. A deleted source file does not
  remove older snapshots; only the explicit `forget --keep-*` policy drops
  data, and it always keeps a daily/weekly/monthly tail.
* Proton holds a byte mirror of the restic repo produced with `rclone copy`
  (never `sync`), so a local change can never delete anything offsite. Stale
  pack files left behind by `restic prune` are harmless: restic ignores packs
  its index does not reference.

The rclone config (the Proton remote) is read from a file owned by the service
user; it is never passed on the command line (argv leaks to `ps`). The restic
repo is created in no-password mode, so there is no secret to lose.
"""

import argparse
import os
import shlex
import subprocess
import sys
from collections import namedtuple

DB_NAME = "immich"
DEFAULT_KEEP_DAILY = "14"
DEFAULT_KEEP_WEEKLY = "8"
DEFAULT_KEEP_MONTHLY = "12"

Repo = namedtuple(
    "Repo",
    [
        "repo",  # restic repository directory on the backup disk
        "library",  # Immich managed library to snapshot
        "dump_file",  # where pg_dump writes before the snapshot
        "rclone_config",  # rclone config holding the Proton remote
        "remote",  # rclone remote name, e.g. "proton"
        "remote_path",  # folder inside the remote, e.g. "immich/restic"
        "keep_daily",
        "keep_weekly",
        "keep_monthly",
    ],
)


def _restic(cfg, *args):
    # The library is not confidential, so the repo is created in restic's
    # no-password mode: there is no secret to lose. A lost password would
    # otherwise render every snapshot, local and offsite, permanently unreadable.
    return ["restic", "-r", cfg.repo, "--insecure-no-password", *args]


def build_steps(cfg, repo_initialized):
    """Return the argv list to run, in order.

    `repo_initialized` is probed separately (a probe is a command too) so this
    stays a pure function and can be asserted on directly.
    """
    steps = []
    if not repo_initialized:
        steps.append(_restic(cfg, "init"))
    steps.append(
        [
            "pg_dump",
            "--no-owner",
            "--clean",
            "--if-exists",
            "--file",
            cfg.dump_file,
            DB_NAME,
        ]
    )
    steps.append(_restic(cfg, "backup", cfg.library, cfg.dump_file))
    steps.append(
        _restic(
            cfg,
            "forget",
            "--keep-daily",
            cfg.keep_daily,
            "--keep-weekly",
            cfg.keep_weekly,
            "--keep-monthly",
            cfg.keep_monthly,
            "--prune",
        )
    )
    steps.append(_restic(cfg, "check"))
    # `copy`, never `sync`: the offsite mirror must never delete anything.
    steps.append(
        [
            "rclone",
            "--config",
            cfg.rclone_config,
            # A failed Proton upload leaves a draft; without this the retry dies
            # with "a draft exist" and the file never reaches the mirror.
            "--protondrive-replace-existing-draft=true",
            "copy",
            cfg.repo,
            f"{cfg.remote}:{cfg.remote_path}",
        ]
    )
    return steps


def quote(argv):
    return " ".join(shlex.quote(part) for part in argv)


def _run(argv):
    return subprocess.run(argv, check=True)


def _repo_initialized(cfg, run):
    try:
        run(_restic(cfg, "cat", "config"))
        return True
    except subprocess.CalledProcessError:
        return False


def run_backup(cfg, dry_run=False, run=_run, out=print):
    os.makedirs(cfg.repo, exist_ok=True)
    os.makedirs(os.path.dirname(cfg.dump_file), exist_ok=True)

    initialized = True
    if not dry_run:
        initialized = _repo_initialized(cfg, run)

    for step in build_steps(cfg, initialized):
        out("+ " + quote(step))
        if not dry_run:
            run(step)
    out("backup complete")


def main(argv=None):
    parser = argparse.ArgumentParser(prog="immich-backup")
    parser.add_argument("--repo", required=True, help="restic repo on the backup disk")
    parser.add_argument("--library", required=True, help="Immich managed library")
    parser.add_argument("--dump-file", required=True, help="pg_dump destination")
    parser.add_argument("--rclone-config", required=True, help="rclone config path")
    parser.add_argument("--remote", default="proton", help="rclone remote name")
    parser.add_argument("--remote-path", default="immich/restic", help="folder on the remote")
    parser.add_argument("--keep-daily", default=DEFAULT_KEEP_DAILY)
    parser.add_argument("--keep-weekly", default=DEFAULT_KEEP_WEEKLY)
    parser.add_argument("--keep-monthly", default=DEFAULT_KEEP_MONTHLY)
    parser.add_argument("--dry-run", action="store_true", help="print steps only")
    args = parser.parse_args(argv)

    cfg = Repo(
        repo=args.repo,
        library=args.library,
        dump_file=args.dump_file,
        rclone_config=args.rclone_config,
        remote=args.remote,
        remote_path=args.remote_path,
        keep_daily=args.keep_daily,
        keep_weekly=args.keep_weekly,
        keep_monthly=args.keep_monthly,
    )
    run_backup(cfg, dry_run=args.dry_run)
    return 0


if __name__ == "__main__":
    sys.exit(main())
