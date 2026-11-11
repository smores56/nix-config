"""Calendar collector for the `ingest-tuta` guest (smores56/sdlc#589).

Tuta has no calendar subscription, so the calendar has to be read with Tuta's
Rust SDK and rendered as ICS here. That fetcher is `pkgs/tuta-ics`: the crate,
the ICS renderer and its unit tests build in Nix, but the SDK feature is gated
(building Tuta's SDK needs the bridge's `sdk-prepare.py` step, a patched
tutanota checkout and bindgen; see `docs/kanbei-ingest-tuta.md`). Until that
build lands, this stub keeps the source honest on the timer:

* if a fetcher dropped an event export at `--events`, the core binary renders
  it and a changed ICS is emitted as one batch item;
* otherwise it emits a single `calendar-unavailable` alert per day, so the gap is
  visible in Kanbei instead of looking like a quiet calendar.

Dedupe is a fingerprint of the rendered ICS in the guest state file, so the
timer never re-emits an unchanged calendar.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone

import policy

SOURCE = "tuta"
STATE_VERSION = 1
UNAVAILABLE = "tuta-ics built without the Tuta SDK feature; no calendar fetcher in this image"
MAX_ICS_BYTES = 512 * 1024


def log(event: str, **fields: object) -> None:
    record = {"ts": datetime.now(timezone.utc).isoformat(timespec="seconds"), "unit": "ingest-tuta-ics", "event": event}
    record.update(fields)
    print(json.dumps(record, sort_keys=True), flush=True)


def fingerprint(ics: str) -> str:
    """Stable digest of the calendar text: line endings and trailing space do not matter."""
    normalized = "\r\n".join(line.rstrip() for line in ics.replace("\r\n", "\n").split("\n")).strip()
    return hashlib.sha256(normalized.encode("utf-8")).hexdigest()


def load_state(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as handle:
            state = json.load(handle)
    except (FileNotFoundError, json.JSONDecodeError):
        return {"version": STATE_VERSION, "seq": 0, "fingerprint": None, "unavailable_epoch": 0}
    if not isinstance(state, dict) or state.get("version") != STATE_VERSION:
        return {"version": STATE_VERSION, "seq": 0, "fingerprint": None, "unavailable_epoch": 0}
    state.setdefault("fingerprint", None)
    state.setdefault("unavailable_epoch", 0)
    state.setdefault("seq", 0)
    return state


def write_state(path: str, state: dict) -> None:
    directory = os.path.dirname(path)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=directory, prefix=".ics-state-", suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(state, handle, sort_keys=True)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)


def changed(state: dict, current: str) -> bool:
    return state.get("fingerprint") != current


def emit(outbox: str, state: dict, kind: str, items: list[dict], *, max_bytes: int) -> str | None:
    """Write one batch for this source; return the file name or None when over the cap."""
    envelope = {
        "v": policy.PROTOCOL_VERSION,
        "source": SOURCE,
        "kind": kind,
        "seq": int(state["seq"]) + 1,
        "sent_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "items": items,
    }
    payload = json.dumps(envelope, sort_keys=True, separators=(",", ":")).encode()
    policy.validate_batch(payload, SOURCE)
    if len(payload) > max_bytes:
        log("reject", reason="batch over the size cap", bytes=len(payload), cap=max_bytes)
        return None
    os.makedirs(outbox, mode=0o700, exist_ok=True)
    name = f"{envelope['seq']:06d}-{kind}-{int(time.time())}.json"
    fd, temporary = tempfile.mkstemp(dir=outbox, prefix=".batch-", suffix=".tmp")
    with os.fdopen(fd, "wb") as handle:
        handle.write(payload)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(temporary, 0o600)
    os.replace(temporary, os.path.join(outbox, name))
    state["seq"] = envelope["seq"]
    return name


def render(binary: str, events: str, out: str) -> str:
    subprocess.run([binary, "--input", events, "--out", out], check=True, timeout=120)
    with open(out, encoding="utf-8") as handle:
        return handle.read()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="ingest-tuta-ics")
    parser.add_argument("--binary", default="/run/current-system/sw/bin/tuta-ics")
    parser.add_argument("--events", default="/var/lib/tutabridge/calendar/events.json")
    parser.add_argument("--out", default="/var/lib/tutabridge/calendar/current.ics")
    parser.add_argument("--state", default="/var/lib/tutabridge/calendar-state.json")
    parser.add_argument("--outbox", default="/var/lib/ingest/outbox")
    parser.add_argument("--max-batch-bytes", type=int, default=policy.MAX_BATCH_BYTES)
    parser.add_argument("--unavailable-cooldown", type=int, default=86400)
    args = parser.parse_args(argv)

    state = load_state(args.state)
    now = int(time.time())
    os.makedirs(os.path.dirname(args.out), mode=0o700, exist_ok=True)

    if os.path.exists(args.events):
        try:
            ics = render(args.binary, args.events, args.out)
        except (OSError, subprocess.SubprocessError) as exc:
            log("retry", reason=f"render failed: {exc}")
            return 1
        if len(ics.encode("utf-8")) > MAX_ICS_BYTES:
            log("reject", reason="calendar exceeds the ICS cap")
            return 65
        current = fingerprint(ics)
        if not changed(state, current):
            log("unchanged", fingerprint=current[:16])
        else:
            name = emit(
                args.outbox,
                state,
                "batch",
                [{"type": "calendar", "format": "ics", "fingerprint": current, "ics": ics}],
                max_bytes=args.max_batch_bytes,
            )
            if name is not None:
                state["fingerprint"] = current
                log("calendar", file=name, bytes=len(ics), fingerprint=current[:16])
    elif now - int(state.get("unavailable_epoch") or 0) >= args.unavailable_cooldown:
        name = emit(
            args.outbox,
            state,
            "alert",
            [{"type": "calendar-unavailable", "reason": UNAVAILABLE}],
            max_bytes=args.max_batch_bytes,
        )
        if name is not None:
            state["unavailable_epoch"] = now
            log("unavailable", file=name)

    write_state(args.state, state)
    return 0


if __name__ == "__main__":
    sys.exit(main())
