"""Brave History collector for the `ingest-brave` guest (smores56/sdlc#591).

The guest runs one Brave profile that is joined to the owner's Sync chain, so
the History database carries every synced visit. This collector takes a
consistent read-only snapshot (SQLite backup API, with a WAL copy fallback for a
database another process holds open), reads `visits JOIN urls` after a
`(visit_time, visit_id)` cursor, and emits visited URLs, titles and timestamps
as NDJSON batches for `ingest-emit`.

Only History is read. Passwords live in Bitwarden and never enter the chain;
bookmarks and open tabs are read only when a future collector is configured for
them. Logs carry counts and ids, never URLs or titles: the batch itself is the
only place visited data appears.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sqlite3
import sys
import tempfile
import time
from datetime import datetime, timezone
from typing import Callable
from urllib import parse as urllib_parse

SOURCE = "brave"
STATE_VERSION = 1
PROTOCOL_VERSION = 1
# Chromium stores microseconds since 1601-01-01 UTC.
CHROMIUM_EPOCH_OFFSET = 11644473600
DEFAULT_LOOKBACK_HOURS = 24
MAX_ITEMS_PER_BATCH = 400
MAX_BATCH_BYTES = 350_000
SEEN_KEEP = 20000
MAX_ROW = 500
COLLECTED_SCHEMES = ("http", "https")


class BraveError(RuntimeError):
    """A refused profile, database or state file."""


def log(event: str, **fields: object) -> None:
    record = {"ts": datetime.now(timezone.utc).isoformat(timespec="seconds"), "unit": "ingest-brave-history", "event": event}
    record.update(fields)
    print(json.dumps(record, sort_keys=True), flush=True)


def webkit_to_epoch(microseconds: int) -> int:
    return int(int(microseconds) // 1_000_000 - CHROMIUM_EPOCH_OFFSET)


def epoch_to_webkit(epoch: int) -> int:
    return (int(epoch) + CHROMIUM_EPOCH_OFFSET) * 1_000_000


def snapshot_database(history: str, target: str) -> str:
    """Copy a live History database consistently; returns the readable path."""
    if not os.path.isfile(history):
        raise BraveError("History database is missing")
    os.makedirs(os.path.dirname(target), mode=0o700, exist_ok=True)
    try:
        source = sqlite3.connect(f"file:{history}?mode=ro", uri=True, timeout=5)
        try:
            destination = sqlite3.connect(target)
            try:
                source.backup(destination)
            finally:
                destination.close()
        finally:
            source.close()
        return target
    except sqlite3.Error:
        pass
    # Brave keeps the database open; copy the file and its WAL beside it.
    staging = tempfile.mkdtemp(dir=os.path.dirname(target), prefix=".history-")
    copied = os.path.join(staging, "History")
    shutil.copy2(history, copied)
    for suffix in ("-wal", "-shm"):
        sidecar = history + suffix
        if os.path.isfile(sidecar):
            shutil.copy2(sidecar, copied + suffix)
    shutil.move(copied, target)
    for suffix in ("-wal", "-shm"):
        staged = copied + suffix
        if os.path.isfile(staged):
            shutil.move(staged, target + suffix)
    shutil.rmtree(staging, ignore_errors=True)
    return target


def open_history(path: str) -> sqlite3.Connection:
    try:
        database = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=10)
        database.execute("SELECT 1 FROM visits LIMIT 1")
        database.execute("SELECT 1 FROM urls LIMIT 1")
    except sqlite3.Error as exc:
        raise BraveError(f"History schema is unreadable: {exc}") from None
    return database


def read_visits(
    database: sqlite3.Connection,
    *,
    after_time: int,
    after_id: int,
    limit: int = MAX_ITEMS_PER_BATCH * 4,
) -> list[dict]:
    rows = database.execute(
        """
        SELECT v.id, v.visit_time, u.url, u.title
        FROM visits AS v JOIN urls AS u ON u.id = v.url
        WHERE v.visit_time > ? OR (v.visit_time = ? AND v.id > ?)
        ORDER BY v.visit_time ASC, v.id ASC
        LIMIT ?
        """,
        (after_time, after_time, after_id, limit),
    ).fetchall()
    visits = []
    for visit_id, visit_time, url, title in rows:
        visits.append(
            {
                "visit_id": int(visit_id),
                "visit_time": int(visit_time),
                "url": str(url or ""),
                "title": str(title or ""),
            }
        )
    return visits


def clean_url(url: str) -> str:
    """Drop the scheme, userinfo, fragments-only pages and absurdly long URLs."""
    text = str(url or "").strip()
    if not text or len(text) > MAX_ROW * 4:
        return ""
    try:
        parts = urllib_parse.urlsplit(text)
    except ValueError:
        return ""
    if parts.scheme not in COLLECTED_SCHEMES or not parts.hostname:
        return ""
    host = parts.hostname
    port = f":{parts.port}" if parts.port else ""
    return urllib_parse.urlunsplit((parts.scheme, host + port, parts.path, parts.query, ""))


def visit_item(visit: dict) -> dict | None:
    url = clean_url(visit["url"])
    if not url:
        return None
    return {
        "type": "browse",
        "url": url[:2000],
        "title": re.sub(r"\s+", " ", visit["title"]).strip()[:MAX_ROW],
        "visited_at": datetime.fromtimestamp(webkit_to_epoch(visit["visit_time"]), timezone.utc).isoformat(
            timespec="seconds"
        ),
        "visit_id": visit["visit_id"],
    }


def visit_key(visit: dict) -> str:
    return hashlib.sha256(f"{visit['url']}\x1f{visit['visit_time']}".encode("utf-8")).hexdigest()


def load_state(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as handle:
            state = json.load(handle)
    except FileNotFoundError:
        return {"version": STATE_VERSION, "seq": 0, "visit_time": 0, "visit_id": 0, "seen": []}
    except (json.JSONDecodeError, UnicodeDecodeError):
        raise BraveError(f"state file {path} is not JSON") from None
    if not isinstance(state, dict) or state.get("version") != STATE_VERSION:
        raise BraveError(f"state file {path} has an unsupported version")
    state.setdefault("seq", 0)
    state.setdefault("visit_time", 0)
    state.setdefault("visit_id", 0)
    state.setdefault("seen", [])
    return state


def write_state(path: str, state: dict) -> None:
    directory = os.path.dirname(path)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=directory, prefix=".brave-state-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(state, handle, sort_keys=True)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def chunk_items(items: list[dict], max_items: int = MAX_ITEMS_PER_BATCH, max_bytes: int = MAX_BATCH_BYTES):
    chunk: list[dict] = []
    size = 2
    for item in items:
        encoded = len(json.dumps(item, sort_keys=True).encode("utf-8")) + 2
        if chunk and (len(chunk) >= max_items or size + encoded > max_bytes):
            yield chunk
            chunk = []
            size = 2
        chunk.append(item)
        size += encoded
    if chunk:
        yield chunk


def write_batch(outbox: str, state: dict, items: list[dict]) -> str:
    seq = int(state.get("seq", 0)) + 1
    envelope = {
        "v": PROTOCOL_VERSION,
        "source": SOURCE,
        "kind": "batch",
        "seq": seq,
        "sent_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "items": items,
    }
    payload = json.dumps(envelope, sort_keys=True, separators=(",", ":")).encode("utf-8")
    os.makedirs(outbox, mode=0o700, exist_ok=True)
    name = f"{seq:06d}-batch-{int(time.time())}.json"
    fd, temporary = tempfile.mkstemp(dir=outbox, prefix=".batch-", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, os.path.join(outbox, name))
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise
    state["seq"] = seq
    return name


def plan_visits(state: dict, visits: list[dict], *, now: int) -> tuple[list[dict], list[dict]]:
    """Return (items, accepted visits) and advance the cursor over every scanned row."""
    seen = set(str(key) for key in state.get("seen", []))
    items: list[dict] = []
    accepted: list[dict] = []
    for visit in visits:
        key = visit_key(visit)
        if key in seen:
            continue
        item = visit_item(visit)
        seen.add(key)
        if item is None:
            continue
        accepted.append(visit)
        items.append(item)
    state["seen"] = sorted(seen)[-SEEN_KEEP:]
    if visits:
        last = max(visits, key=lambda visit: (visit["visit_time"], visit["visit_id"]))
        stored = (int(state.get("visit_time") or 0), int(state.get("visit_id") or 0))
        if (last["visit_time"], last["visit_id"]) > stored:
            state["visit_time"] = last["visit_time"]
            state["visit_id"] = last["visit_id"]
    return items, accepted


def collect(
    history: str,
    state: dict,
    outbox: str,
    *,
    workdir: str,
    now: int | None = None,
    lookback_hours: int = DEFAULT_LOOKBACK_HOURS,
) -> dict:
    now = int(now if now is not None else time.time())
    started = int(state.get("visit_time") or 0)
    if started <= 0:
        started = epoch_to_webkit(now - lookback_hours * 3600)
        # A first run must not re-scan the same lookback on every pass.
        state["visit_time"] = started
        state["visit_id"] = 0
    database = open_history(snapshot_database(history, os.path.join(workdir, "History")))
    try:
        scanned = 0
        accepted_count = 0
        batches = 0
        while True:
            visits = read_visits(
                database,
                after_time=int(state.get("visit_time") or 0),
                after_id=int(state.get("visit_id") or 0),
            )
            if not visits:
                break
            items, accepted = plan_visits(state, visits, now=now)
            scanned += len(visits)
            accepted_count += len(accepted)
            for chunk in chunk_items(items):
                write_batch(outbox, state, chunk)
                batches += 1
            if len(visits) < MAX_ITEMS_PER_BATCH * 4:
                break
    finally:
        database.close()
    state["scanned_at"] = now
    log("done", scans=scanned, emitted=accepted_count, batches=batches)
    return {"scanned": scanned, "emitted": accepted_count, "batches": batches}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="ingest-brave-history")
    parser.add_argument("--profile", default="/var/lib/brave/profile")
    parser.add_argument("--history", help="History database (default: <profile>/Default/History)")
    parser.add_argument("--state", default="/var/lib/brave/state.json")
    parser.add_argument("--outbox", default="/var/lib/ingest/outbox")
    parser.add_argument("--workdir", default="/var/lib/brave/work")
    parser.add_argument("--lookback-hours", type=int, default=DEFAULT_LOOKBACK_HOURS)
    args = parser.parse_args(argv)
    history = args.history or os.path.join(args.profile, "Default", "History")
    try:
        state = load_state(args.state)
        summary = collect(
            history,
            state,
            args.outbox,
            workdir=args.workdir,
            lookback_hours=max(1, args.lookback_hours),
        )
        write_state(args.state, state)
        log("saved", **summary)
        return 0
    except (OSError, BraveError, sqlite3.Error) as exc:
        log("error", reason=str(exc))
        return 65


if __name__ == "__main__":
    sys.exit(main())
