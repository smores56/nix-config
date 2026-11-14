"""Freshness heartbeat for the ingest plane.

Runs every 5 minutes (ingest-heartbeat.timer). It reads each source's last
successful batch from root-only state and writes one age-encrypted heartbeat
envelope into the inbox, so Kanbei sees both freshness and staleness. A source
past its per-source window raises the host alert through the existing
`cloudflare-email@` template, rate-limited to once per window.

The batch state file is `state/<source>.last-ok` (0600 root); the heartbeat
envelope is `heartbeat-<epoch>.age` (0600 root; the inbox share is read by guest root only).
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone

import policy


def log(event: str, **fields: object) -> None:
    record = {"ts": datetime.now(timezone.utc).isoformat(timespec="seconds"), "unit": "ingest-heartbeat", "event": event}
    record.update(fields)
    print(json.dumps(record, sort_keys=True), flush=True)


def freshness_sources(data: dict) -> dict[str, dict]:
    """Sources Kanbei consumes.

    A query channel (`search`) shares the source table but has no guest
    consumer; publishing it in the envelope quarantined the whole heartbeat,
    so the guest never saw a verdict for any source.
    """
    merged = {**data["sources"], **data.get("hostSources", {})}
    return {
        name: entry for name, entry in merged.items() if entry.get("heartbeat", True)
    }


def read_state(state_dir: str, source: str) -> dict | None:
    try:
        with open(os.path.join(state_dir, f"{source}.last-ok"), encoding="utf-8") as handle:
            return json.load(handle)
    except (FileNotFoundError, json.JSONDecodeError):
        return None


def write_atomic(path: str, data: bytes, mode: int) -> None:
    directory = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".heartbeat-", suffix=".tmp")
    with os.fdopen(fd, "wb") as handle:
        handle.write(data)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def encrypt(recipient: str, payload: bytes, directory: str) -> str:
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".heartbeat-", suffix=".age.tmp")
    try:
        with os.fdopen(fd, "wb") as out:
            proc = subprocess.run(
                ["age", "--encrypt", "-r", recipient],
                input=payload,
                stdout=out,
                stderr=subprocess.PIPE,
                check=False,
            )
        if proc.returncode != 0:
            raise RuntimeError(proc.stderr.decode("utf-8", "replace").strip())
        return tmp
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


def alert(state_dir: str, source: str, window: int, now: int, enabled: bool) -> bool:
    marker = os.path.join(state_dir, f"{source}.alerted")
    try:
        with open(marker, encoding="utf-8") as handle:
            last = int(handle.read().strip())
    except (FileNotFoundError, ValueError):
        last = 0
    if last and now - last < window:
        return False
    log("alert", source=source, window_s=window, last_alert=last)
    if enabled:
        subprocess.run(
            ["systemctl", "start", "--no-block", f"cloudflare-email@ingest-writer-{source}.service"],
            check=False,
        )
        write_atomic(marker, f"{now}\n".encode(), 0o600)
    return True


def prune(inbox: str, retain_hours: int, now: float) -> int:
    cutoff = now - retain_hours * 3600
    removed = 0
    for name in os.listdir(inbox):
        if not (name.startswith("heartbeat-") and name.endswith(".age")):
            continue
        path = os.path.join(inbox, name)
        try:
            if os.path.getmtime(path) < cutoff:
                os.unlink(path)
                removed += 1
        except FileNotFoundError:
            pass
    return removed


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="ingest-heartbeat")
    parser.add_argument("--policy", required=True)
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--inbox", required=True)
    parser.add_argument("--recipient-file", required=True)
    parser.add_argument("--retain-hours", type=int, default=168)
    parser.add_argument("--no-alert", action="store_true")
    args = parser.parse_args(argv)

    with open(args.policy, encoding="utf-8") as handle:
        data = json.load(handle)
    try:
        with open(args.recipient_file, encoding="utf-8") as handle:
            recipient = policy.validate_age_recipient(handle.read())
    except FileNotFoundError:
        log("no-recipient", path=args.recipient_file)
        return 0
    except policy.PolicyError as exc:
        log("error", reason=f"invalid recipient: {exc}")
        return 1

    now = int(time.time())
    # Host-written sources (the cluster digest) share the state shape and the
    # alert path with the guests; only the emitter differs.
    host_sources: dict[str, dict] = data.get("hostSources", {})
    all_sources = freshness_sources(data)
    statuses: dict[str, dict] = {}
    stale_sources: list[tuple[str, int]] = []
    for source, entry in sorted(all_sources.items()):
        window = int(entry["windowSeconds"])
        state = read_state(args.state_dir, source)
        last_epoch = int(state["epoch"]) if state else None
        stale = last_epoch is None or now - last_epoch > window
        statuses[source] = {
            "stale": stale,
            "host": source in host_sources,
            "window_s": window,
            "last_ok": state["last_ok"] if state else None,
            "age_s": None if last_epoch is None else now - last_epoch,
        }
        if stale:
            stale_sources.append((source, window))

    envelope = {
        "v": policy.PROTOCOL_VERSION,
        "kind": "heartbeat",
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "sources": statuses,
        "host_sources": sorted(name for name in host_sources if name in all_sources),
    }
    policy.validate_heartbeat(envelope)
    payload = json.dumps(envelope, sort_keys=True).encode()
    tmp = encrypt(recipient, payload, args.inbox)
    target = os.path.join(args.inbox, f"heartbeat-{now}.age")
    os.chmod(tmp, 0o600)
    os.replace(tmp, target)

    alerted = [
        source
        for source, window in stale_sources
        if all_sources[source].get("alert", True)
        and alert(args.state_dir, source, window, now, not args.no_alert)
    ]
    removed = prune(args.inbox, args.retain_hours, now)
    log(
        "heartbeat",
        file=os.path.basename(target),
        stale=[s for s, _ in stale_sources],
        alerted=alerted,
        pruned=removed,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
