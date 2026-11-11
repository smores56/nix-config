"""Refcounted freeze/thaw for the kanbei guest's restic jobs.

Two restic jobs (`kanbei-r2`, `kanbei-local`) snapshot the same LUKS image. Each uses
`backupPrepareCommand`/`backupCleanupCommand`, which run as separate processes, so a
"was the VM running?" marker cannot be shared safely: job A stops the VM, job B sees it
down and does not mark it, then B's cleanup starts the VM while A is still snapshotting.

This helper keeps a job-keyed refcount under a flock so the VM is stopped only when the
first job arrives and started only when the last job leaves. A job that dies without its
cleanup (restic killed, host reboot) would otherwise pin the guest down forever, so each
entry carries its start time and expires after `--stale-after` seconds on the next
prepare or cleanup. The side effects (systemctl stop/start) are injected, which is what
the unit tests exercise.
"""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import json
import os
import subprocess
import sys
import tempfile
import time

STATE_FILE = "backup-refs.json"
DEFAULT_STALE_AFTER = 12 * 3600


def empty_state() -> dict:
    return {"jobs": {}, "was_active": False}


def load(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (FileNotFoundError, json.JSONDecodeError):
        return empty_state()
    if not isinstance(data, dict) or not isinstance(data.get("jobs"), dict):
        return empty_state()
    jobs = {
        str(job): int(started)
        for job, started in data["jobs"].items()
        if isinstance(job, str) and isinstance(started, int) and started > 0
    }
    return {"jobs": jobs, "was_active": bool(data.get("was_active"))}


def save(path: str, state: dict) -> None:
    directory = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".backup-refs.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(state, handle, sort_keys=True)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(tmp)
        raise


def prune(state: dict, now: int, stale_after: int) -> dict:
    """Drop entries older than ``stale_after``; a crashed job must not pin the guest."""
    jobs = {
        job: started for job, started in state["jobs"].items() if now - started < stale_after
    }
    return {"jobs": jobs, "was_active": state["was_active"] if jobs else False}


def decide(
    state: dict,
    *,
    action: str,
    job: str,
    now: int,
    stale_after: int = DEFAULT_STALE_AFTER,
    active: bool = False,
) -> tuple[dict, bool, bool]:
    """Return ``(next_state, stop, start)`` for one prepare or cleanup.

    ``stop`` is True only for the first prepare; ``start`` only when the last cleanup
    holds the marker and the VM was running before the first prepare.
    """
    live = prune(state, now, stale_after)
    if action == "prepare":
        first = not live["jobs"]
        if first:
            live = {"jobs": {}, "was_active": bool(active)}
        jobs = dict(live["jobs"])
        jobs[job] = now
        return {"jobs": jobs, "was_active": live["was_active"]}, first and active, False
    if action != "cleanup":
        raise ValueError(f"unknown action {action}")
    jobs = {key: value for key, value in live["jobs"].items() if key != job}
    if jobs:
        return {"jobs": jobs, "was_active": live["was_active"]}, False, False
    return {"jobs": {}, "was_active": False}, False, live["was_active"]


@contextlib.contextmanager
def locked(path: str):
    """Serialise prepare/cleanup across jobs; the lock lives beside the state file."""
    lock_path = f"{path}.lock"
    with open(lock_path, "a+", encoding="utf-8") as handle:
        os.chmod(lock_path, 0o600)
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def run(
    *,
    run_dir: str,
    action: str,
    job: str,
    systemctl: str,
    unit: str,
    stale_after: int = DEFAULT_STALE_AFTER,
    clock=time.time,
    active=None,
    stop=None,
    start=None,
) -> dict:
    """Apply one action under the lock and return the resulting state."""
    path = os.path.join(run_dir, STATE_FILE)
    os.makedirs(run_dir, mode=0o700, exist_ok=True)

    def unit_active() -> bool:
        if active is not None:
            return active()
        return (
            subprocess.run(
                [systemctl, "is-active", "--quiet", unit], check=False
            ).returncode
            == 0
        )

    def unit_stop() -> None:
        if stop is not None:
            stop()
            return
        subprocess.run([systemctl, "stop", unit], check=False)

    def unit_start() -> None:
        if start is not None:
            start()
            return
        subprocess.run([systemctl, "start", unit], check=False)

    with locked(path):
        state = load(path)
        if action == "reset":
            was_active = state["was_active"]
            save(path, empty_state())
            if was_active:
                unit_start()
            return empty_state()
        next_state, do_stop, do_start = decide(
            state, action=action, job=job, now=int(clock()), stale_after=stale_after,
            active=unit_active() if action == "prepare" else False,
        )
        save(path, next_state)
        if do_stop:
            unit_stop()
        if do_start:
            unit_start()
        return next_state


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="kanbei-freeze")
    parser.add_argument("--run-dir", default="/run/kanbei-vm")
    parser.add_argument("--job", required=True, help="restic job id (unit suffix)")
    parser.add_argument("--unit", default="microvm@kanbei.service")
    parser.add_argument("--systemctl", default="systemctl")
    parser.add_argument("--stale-after", type=int, default=DEFAULT_STALE_AFTER)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--prepare", action="store_true")
    group.add_argument("--cleanup", action="store_true")
    group.add_argument("--reset", action="store_true", help="clear a stale refcount")
    args = parser.parse_args(argv)
    action = "prepare" if args.prepare else "cleanup" if args.cleanup else "reset"
    state = run(
        run_dir=args.run_dir,
        action=action,
        job=args.job,
        systemctl=args.systemctl,
        unit=args.unit,
        stale_after=args.stale_after,
    )
    print(json.dumps(state, sort_keys=True), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
