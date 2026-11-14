"""Host writer for the cluster digest (smores56/sdlc#595, part of #509).

The `cluster` guest's CronJob rewrites `/mnt/data/cluster-digest/latest.json`
every 15 minutes (the same host tree at
`/var/lib/kanbei-ingest/shares/cluster-digest`, shared read-write into the
guest). This writer watches that one file and, for every document whose
`generated_at` is newer than the cursor, age-encrypts the exact bytes into
Kanbei's read-only inbox as `cluster-digest-<UTC>.age`.

The platform writer already renames `latest.json` into place atomically, but a
reader still has to prove it did not see a half-written or virtiofs-stale file:
`read_stable` stats the file before and after the read and retries when inode,
size or mtime move, and the payload must parse and validate before the cursor
advances. `generated_at` is the dedupe key, so restarting the writer never
re-emits a document and a replayed `latest.json` is skipped.

Freshness: the writer records `state/cluster-digest.last-ok` in the shape the
T14 heartbeat reads, and raises the same `cloudflare-email@` alert once per
window when the newest `generated_at` is older than the window (or when no
digest has ever arrived). The heartbeat envelope also carries the digest as a
host source, so staleness is visible in Kanbei as well as paged.
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
from typing import Callable

import policy
import writer

SOURCE = "cluster-digest"
SCHEMA_VERSION = "1"
# The CronJob's own DIGEST_MAX_BYTES. A larger document means the platform
# changed its contract, which must page instead of being truncated here.
MAX_DIGEST_BYTES = 64 * 1024
STAMP_FORMAT = "%Y%m%dT%H%M%SZ"


class DigestError(ValueError):
    """A document, cursor or timestamp the writer refuses."""


def log(event: str, **fields: object) -> None:
    record = {"ts": datetime.now(timezone.utc).isoformat(timespec="seconds"), "unit": SOURCE, "event": event}
    record.update(fields)
    print(json.dumps(record, sort_keys=True), flush=True)


def parse_timestamp(text: object) -> int:
    """Parse the platform's `iso()` value (`...Z` or an explicit offset) to epoch seconds."""
    if not isinstance(text, str) or not text:
        raise DigestError("generated_at is not a string")
    candidate = text[:-1] + "+00:00" if text.endswith("Z") else text
    try:
        moment = datetime.fromisoformat(candidate)
    except ValueError as exc:
        raise DigestError(f"generated_at is not ISO-8601: {text!r}") from exc
    if moment.tzinfo is None:
        raise DigestError("generated_at has no timezone")
    return int(moment.timestamp())


def parse_digest(payload: bytes, max_bytes: int = MAX_DIGEST_BYTES) -> tuple[dict, int]:
    """Validate one digest document and return it with its `generated_at` epoch."""
    if not isinstance(payload, (bytes, bytearray)) or not payload:
        raise DigestError("digest is empty")
    if len(payload) > max_bytes:
        raise DigestError(f"digest is {len(payload)} bytes, over the {max_bytes} cap")
    try:
        document = json.loads(bytes(payload).decode("utf-8"))
    except UnicodeDecodeError as exc:
        raise DigestError("digest is not UTF-8") from exc
    except json.JSONDecodeError as exc:
        raise DigestError(f"digest is not JSON: {exc.msg}") from exc
    if not isinstance(document, dict):
        raise DigestError("digest is not an object")
    if document.get("schema_version") != SCHEMA_VERSION:
        raise DigestError(f"unsupported digest schema_version {document.get('schema_version')!r}")
    epoch = parse_timestamp(document.get("generated_at"))
    for section in ("cluster", "nanobot_activity"):
        if not isinstance(document.get(section), dict):
            raise DigestError(f"digest section {section} is missing")
    return document, epoch


def stamp_of(epoch: int) -> str:
    return datetime.fromtimestamp(epoch, tz=timezone.utc).strftime(STAMP_FORMAT)


def is_newer(cursor_epoch: int | None, epoch: int) -> bool:
    """Strictly newer: an equal `generated_at` is a replay, an older one is out of order."""
    return cursor_epoch is None or epoch > cursor_epoch


def read_seq(state_dir: str, source: str = SOURCE) -> int:
    """The last sequence this writer emitted; 0 before the first document."""
    try:
        with open(os.path.join(state_dir, f"{source}.cursor"), encoding="utf-8") as handle:
            record = json.load(handle)
        return max(0, int(record.get("seq", 0)))
    except (FileNotFoundError, ValueError, KeyError, TypeError):
        return 0


def wire_envelope(document: bytes, seq: int) -> bytes:
    """Wrap the digest document in the ingest wire envelope.

    Every other producer ships `{v, source, kind, seq, sent_at, items}` and the
    guest's inbox reader parses nothing else, so the raw document was never
    ingestible: it quarantined as `parse_failed` on every new digest.
    """
    parsed = json.loads(bytes(document).decode("utf-8"))
    envelope = {
        "v": policy.PROTOCOL_VERSION,
        "source": SOURCE,
        "kind": "batch",
        "seq": seq,
        "sent_at": parsed["generated_at"],
        "items": [parsed],
    }
    payload = json.dumps(envelope, sort_keys=True).encode("utf-8")
    policy.validate_batch(payload, SOURCE)
    return payload


def read_stable(
    path: str,
    *,
    max_bytes: int = MAX_DIGEST_BYTES,
    attempts: int = 5,
    delay: float = 0.2,
    sleep: Callable[[float], None] = time.sleep,
) -> bytes:
    """Read a file whose writer renames into place; refuse a read that observed churn.

    A rename changes the inode; an in-place rewrite changes size or mtime. When
    either changes across the read, the bytes are untrustworthy and are read
    again. A file that never settles is an error, not a short read.
    """
    for attempt in range(1, attempts + 1):
        try:
            before = os.stat(path)
        except FileNotFoundError:
            raise
        if not os.path.isfile(path):
            raise DigestError(f"{path} is not a regular file")
        if before.st_size > max_bytes:
            raise DigestError(f"{path} is {before.st_size} bytes, over the {max_bytes} cap")
        with open(path, "rb") as handle:
            payload = handle.read(max_bytes + 1)
        after = os.stat(path)
        if (
            before.st_ino == after.st_ino
            and before.st_size == after.st_size
            and before.st_mtime_ns == after.st_mtime_ns
            and len(payload) == after.st_size
        ):
            return payload
        log("retry", reason="file changed during read", attempt=attempt, path=path)
        sleep(delay)
    raise DigestError(f"{path} did not settle after {attempts} reads")


def read_cursor(state_dir: str, source: str = SOURCE) -> int | None:
    try:
        with open(os.path.join(state_dir, f"{source}.cursor"), encoding="utf-8") as handle:
            record = json.load(handle)
        return int(record["epoch"])
    except (FileNotFoundError, ValueError, KeyError, TypeError):
        return None


def write_atomic(path: str, data: bytes, mode: int) -> None:
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".digest-", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


def record_state(
    state_dir: str,
    *,
    epoch: int,
    target: str,
    batches: int,
    seq: int = 0,
) -> None:
    """Advance the cursor and the heartbeat's last-ok in that order.

    The cursor decides dedupe; `last-ok` decides freshness. Both are replaced
    atomically, so a crash between them re-emits one document at worst.
    """
    generated = datetime.fromtimestamp(epoch, tz=timezone.utc).isoformat(timespec="seconds")
    cursor = {"generated_at": generated, "epoch": epoch, "file": os.path.basename(target), "seq": seq}
    write_atomic(
        os.path.join(state_dir, f"{SOURCE}.cursor"),
        json.dumps(cursor, sort_keys=True).encode(),
        0o600,
    )
    last_ok = {
        "source": SOURCE,
        "last_ok": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "epoch": epoch,
        "batches": batches,
        "last_file": os.path.basename(target),
    }
    write_atomic(
        os.path.join(state_dir, f"{SOURCE}.last-ok"),
        json.dumps(last_ok, sort_keys=True).encode(),
        0o600,
    )


def emit(
    inbox: str,
    recipient: str,
    payload: bytes,
    *,
    stamp: str,
    encrypt: Callable[[str, bytes, str], str] | None = None,
) -> str:
    """Encrypt one document and rename it into the inbox under its digest stamp."""
    tmp = (encrypt or writer.encrypt_to)(recipient, payload, inbox)
    target = os.path.join(inbox, f"{SOURCE}-{stamp}.age")
    os.chmod(tmp, 0o600)
    os.replace(tmp, target)
    return target


def read_recipient(path: str) -> str | None:
    try:
        with open(path, encoding="utf-8") as handle:
            return policy.validate_age_recipient(handle.read())
    except FileNotFoundError:
        return None
    except policy.PolicyError as exc:
        raise DigestError(f"invalid age recipient in {path}: {exc}") from exc


def alert(
    state_dir: str,
    *,
    window: int,
    now: int,
    last_epoch: int,
    run: Callable[..., object] = subprocess.run,
    enabled: bool = True,
) -> bool:
    """Page at most once per window, sharing the heartbeat's marker file."""
    marker = os.path.join(state_dir, f"{SOURCE}.alerted")
    try:
        with open(marker, encoding="utf-8") as handle:
            last = int(handle.read().strip())
    except (FileNotFoundError, ValueError):
        last = 0
    if last and now - last < window:
        return False
    log("alert", source=SOURCE, window_s=window, age_s=now - last_epoch, last_alert=last)
    if enabled:
        run(
            ["systemctl", "start", "--no-block", f"cloudflare-email@ingest-writer-{SOURCE}.service"],
            check=False,
        )
        write_atomic(marker, f"{now}\n".encode(), 0o600)
    return True


def pending(args: argparse.Namespace, state_dir: str) -> tuple[bytes, dict, int] | None:
    """Return (payload, document, epoch) for a new document, or None."""
    try:
        payload = read_stable(args.file, max_bytes=args.max_bytes)
    except FileNotFoundError:
        log("waiting", reason="digest missing", path=args.file)
        return None
    document, epoch = parse_digest(payload, args.max_bytes)
    cursor = read_cursor(state_dir)
    if not is_newer(cursor, epoch):
        log("duplicate", generated_at=document["generated_at"], cursor_epoch=cursor)
        return None
    return payload, document, epoch


def cycle(
    args: argparse.Namespace,
    *,
    batches: int,
    started: int,
    run: Callable[..., object] = subprocess.run,
) -> int:
    """One pass: emit any new digest, then page if the newest one is stale."""
    os.makedirs(args.state_dir, exist_ok=True)
    now = int(time.time())
    fresh = pending(args, args.state_dir)
    if fresh is not None:
        payload, document, epoch = fresh
        recipient = read_recipient(args.recipient_file)
        if recipient is None:
            log("waiting", reason="recipient missing", path=args.recipient_file)
        else:
            seq = read_seq(args.state_dir) + 1
            wire = wire_envelope(payload, seq)
            target = emit(args.inbox, recipient, wire, stamp=stamp_of(epoch))
            record_state(
                args.state_dir,
                epoch=epoch,
                target=target,
                batches=batches + 1,
                seq=seq,
            )
            batches += 1
            log(
                "digest",
                generated_at=document["generated_at"],
                bytes=len(wire),
                seq=seq,
                file=os.path.basename(target),
            )
            now = int(time.time())

    last_epoch = read_cursor(args.state_dir) or started
    if args.stale_alert and now - last_epoch > args.window:
        alert(args.state_dir, window=args.window, now=now, last_epoch=last_epoch, run=run)
    return batches


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="ingest-digest")
    parser.add_argument("--source", default=SOURCE, choices=[SOURCE])
    parser.add_argument("--file", required=True, help="latest.json inside the digest share")
    parser.add_argument("--recipient-file", required=True)
    parser.add_argument("--inbox", required=True)
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--interval", type=float, default=5.0)
    parser.add_argument("--window", type=int, default=3600, help="staleness window in seconds")
    parser.add_argument("--max-bytes", type=int, default=MAX_DIGEST_BYTES)
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--no-alert", dest="stale_alert", action="store_false")
    args = parser.parse_args(argv)

    for directory in (args.inbox, args.state_dir):
        if not os.path.isdir(directory):
            log("error", message=f"directory missing: {directory}")
            return 65
    started = int(time.time())
    batches = 0
    log("start", file=args.file, window_s=args.window, max_bytes=args.max_bytes)
    while True:
        try:
            batches = cycle(args, batches=batches, started=started)
        except DigestError as exc:
            log("reject", reason=str(exc))
            return 65
        except (OSError, RuntimeError) as exc:
            log("retry", reason=str(exc))
        if args.once:
            return 0
        time.sleep(args.interval)


if __name__ == "__main__":
    sys.exit(main())
