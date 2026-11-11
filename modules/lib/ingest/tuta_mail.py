"""Mail collector for the `ingest-tuta` guest (smores56/sdlc#589).

TutaBridge exposes the owner's Tuta account as a loopback IMAP/SMTP server. This
collector talks IMAP only (`BODY.PEEK`, so it never marks a message read), keeps
a per-folder UID cursor in one JSON state file, and writes NDJSON batches into
`/var/lib/ingest/outbox` for `ingest-emit` to ship to the host writer.

Dedupe is by UID plus UIDVALIDITY: a folder whose UIDVALIDITY changed is
re-baselined instead of replaying ids that now refer to other messages. A folder
seen for the first time is baselined without emitting, so the first boot does
not dump the whole mailbox into Kanbei.

Two conditions page the owner, both as an `alert` batch the host writer turns
into the existing `cloudflare-email@` unit:

* any new message in the Sent folder (the session is send-capable, so a new Sent
  item is the tamper signal);
* the bridge log naming a Tuta client-version rejection or a rejected saved
  session, which needs a one-time login or a TutaBridge bump.

One IDLE wait per pass, then a `UID SEARCH` over every folder; IDLE is capped far
inside the 29-minute server window, every socket has a timeout, reconnects back
off, and no log line carries a password, address, subject or body.
"""

from __future__ import annotations

import argparse
import email
import email.header
import html
import imaplib
import json
import os
import re
import socket
import ssl
import sys
import tempfile
import time
from datetime import datetime, timezone
from email import policy as email_policy
from email.message import Message

import policy
import tuta_session

SOURCE = "tuta"
STATE_VERSION = 1
SENT_NAMES = ("sent", "sent items", "sent mail", "gesendet", "envoyés")
# IDLE must be re-issued well inside the 29-minute server window.
IDLE_SECONDS = 120
UID_KEEP = 2000
REJECTIONS = (
    ("minimum-client", re.compile(r"tuta rejects this version", re.IGNORECASE)),
    ("session-rejected", re.compile(r"saved session rejected", re.IGNORECASE)),
)


def log(event: str, **fields: object) -> None:
    record = {"ts": datetime.now(timezone.utc).isoformat(timespec="seconds"), "unit": "ingest-tuta-mail", "event": event}
    record.update(fields)
    print(json.dumps(record, sort_keys=True), flush=True)


class MailError(RuntimeError):
    """A refused state file, batch or IMAP response."""


def load_state(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as handle:
            state = json.load(handle)
    except FileNotFoundError:
        return {"version": STATE_VERSION, "seq": 0, "folders": {}, "alerts": {}, "log_offset": 0}
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise MailError(f"state file {path} is not JSON") from exc
    if not isinstance(state, dict) or state.get("version") != STATE_VERSION:
        raise MailError(f"state file {path} has an unsupported version")
    state.setdefault("folders", {})
    state.setdefault("alerts", {})
    state.setdefault("seq", 0)
    state.setdefault("log_offset", 0)
    return state


def write_state(path: str, state: dict) -> None:
    directory = os.path.dirname(path)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=directory, prefix=".mail-state-", suffix=".tmp")
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


def folder_kind(name: str) -> str:
    """Classify a folder path by its last label: `sent`, `inbox` or `other`."""
    leaf = re.split(r"[/.]", str(name or ""))[-1].strip().lower()
    if leaf in SENT_NAMES:
        return "sent"
    if leaf == "inbox":
        return "inbox"
    return "other"


def is_sent_folder(name: str) -> bool:
    return folder_kind(name) == "sent"


def uid_list(reply: object) -> list[int]:
    """Flatten an IMAP SEARCH reply into sorted unique UIDs."""
    if not reply:
        return []
    if isinstance(reply, (bytes, bytearray)):
        reply = [reply]
    uids: set[int] = set()
    for chunk in reply:
        if not isinstance(chunk, (bytes, bytearray)):
            continue
        for token in bytes(chunk).split():
            try:
                uid = int(token)
            except ValueError:
                continue
            if uid > 0:
                uids.add(uid)
    return sorted(uids)


def new_uids(known: list[int], present: list[int]) -> list[int]:
    seen = set(known)
    return [uid for uid in present if uid not in seen]


def merge_uids(known: list[int], present: list[int], keep: int = UID_KEEP) -> list[int]:
    merged = sorted(set(known) | set(present))
    return merged[-keep:]


def folder_cursor(state: dict, folder: str) -> dict:
    entry = state["folders"].get(folder)
    if not isinstance(entry, dict):
        entry = {"uidvalidity": None, "uids": []}
        state["folders"][folder] = entry
    entry.setdefault("uids", [])
    return entry


def plan_folder(
    state: dict,
    folder: str,
    uidvalidity: int | None,
    present: list[int],
    *,
    baseline: bool = True,
) -> tuple[list[int], str]:
    """Return (UIDs to emit, action) and advance the cursor in the same step.

    `baseline` suppresses the first-sight backfill; a UIDVALIDITY change always
    resets without emitting, because the old ids now name different messages.
    """
    entry = folder_cursor(state, folder)
    stored = entry.get("uidvalidity")
    if stored is not None and stored != uidvalidity:
        entry["uidvalidity"] = uidvalidity
        entry["uids"] = merge_uids([], present)
        return [], "uidvalidity-reset"
    known = [uid for uid in entry.get("uids", []) if isinstance(uid, int)]
    if stored is None:
        entry["uidvalidity"] = uidvalidity
        entry["uids"] = merge_uids([], present)
        return ([], "baseline") if baseline else (sorted(present), "backfill")
    fresh = new_uids(known, present)
    entry["uidvalidity"] = uidvalidity
    entry["uids"] = merge_uids(known, present)
    return fresh, "delta"


def decode_header(value: str | None) -> str:
    if not value:
        return ""
    try:
        return str(email.header.make_header(email.header.decode_header(value)))[:512]
    except (UnicodeDecodeError, ValueError):
        return str(value)[:512]


def text_body(message: Message, max_bytes: int) -> str:
    """Prefer text/plain; fall back to tag-stripped HTML; cap at max_bytes."""
    chosen = None
    if message.is_multipart():
        plain = None
        rich = None
        for part in message.walk():
            if part.get_content_maintype() != "text" or part.get_filename():
                continue
            if part.get_content_subtype() == "plain" and plain is None:
                plain = part
            elif part.get_content_subtype() == "html" and rich is None:
                rich = part
        chosen = plain or rich
    else:
        chosen = message
    if chosen is None:
        return ""
    try:
        payload = chosen.get_payload(decode=True) or b""
    except (AssertionError, ValueError):
        return ""
    charset = chosen.get_content_charset() or "utf-8"
    try:
        text = payload.decode(charset, "replace")
    except LookupError:
        text = payload.decode("utf-8", "replace")
    if chosen.get_content_subtype() == "html":
        text = html.unescape(re.sub(r"<[^>]+>", " ", text))
        text = re.sub(r"[ \t\r\f\v]+", " ", text)
    elif chosen.get_content_subtype() == "plain":
        text = html.unescape(text) if "&" in text else text
    text = text.replace("\x00", "")
    return text.encode("utf-8")[:max_bytes].decode("utf-8", "ignore")


def summarize(raw: bytes, folder: str, uid: int, max_body_bytes: int) -> dict:
    """One mail item: headers, a capped text body, and no attachment bytes."""
    message = email.message_from_bytes(raw, policy=email_policy.default)
    return {
        "type": "mail",
        "folder": folder,
        "uid": uid,
        "date": decode_header(message.get("Date")),
        "from": decode_header(message.get("From")),
        "to": decode_header(message.get("To")),
        "subject": decode_header(message.get("Subject")),
        "message_id": decode_header(message.get("Message-ID")),
        "body": text_body(message, max_body_bytes),
    }


def sent_alert(item: dict) -> dict:
    """The Sent signal carries no body: the owner needs to know, not to read it here."""
    return {
        "type": "sent-alert",
        "folder": item["folder"],
        "uid": item["uid"],
        "date": item["date"],
        "to": item["to"],
        "subject": item["subject"],
        "message_id": item["message_id"],
    }


def rejection_reason(line: str) -> str | None:
    for reason, pattern in REJECTIONS:
        if pattern.search(line):
            return reason
    return None


def batch_bytes(source: str, kind: str, seq: int, items: list[dict], *, size_cap: int) -> bytes:
    envelope = {
        "v": policy.PROTOCOL_VERSION,
        "source": source,
        "kind": kind,
        "seq": seq,
        "sent_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "items": items,
    }
    payload = json.dumps(envelope, sort_keys=True, separators=(",", ":")).encode()
    policy.validate_batch(payload, source)
    if len(payload) > size_cap:
        raise MailError(f"batch is {len(payload)} bytes, over the {size_cap} cap")
    return payload


def chunk_items(items: list[dict], max_items: int, max_bytes: int) -> list[list[dict]]:
    """Split items into batches that respect both the count and the byte budget."""
    chunks: list[list[dict]] = []
    current: list[dict] = []
    size = 256  # envelope slack
    for item in items:
        item_size = len(json.dumps(item, sort_keys=True, separators=(",", ":")).encode()) + 1
        if item_size > max_bytes:
            raise MailError("one mail item exceeds the batch cap")
        if current and (len(current) >= max_items or size + item_size > max_bytes):
            chunks.append(current)
            current = []
            size = 256
        current.append(item)
        size += item_size
    if current:
        chunks.append(current)
    return chunks


def write_outbox(outbox: str, name: str, payload: bytes) -> str:
    os.makedirs(outbox, mode=0o700, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=outbox, prefix=".batch-", suffix=".tmp")
    with os.fdopen(fd, "wb") as handle:
        handle.write(payload)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(temporary, 0o600)
    target = os.path.join(outbox, name)
    os.replace(temporary, target)
    return target


def emit_batches(
    outbox: str,
    state: dict,
    kind: str,
    items: list[dict],
    *,
    max_items: int,
    max_bytes: int,
) -> list[str]:
    """Write every chunk as its own outbox file and advance `seq` per batch."""
    written: list[str] = []
    if not items:
        return written
    for chunk in chunk_items(items, max_items, max_bytes):
        seq = int(state["seq"]) + 1
        payload = batch_bytes(SOURCE, kind, seq, chunk, size_cap=max_bytes)
        name = f"{seq:06d}-{kind}-{int(time.time())}.json"
        written.append(write_outbox(outbox, name, payload))
        state["seq"] = seq
        log("batch", kind=kind, seq=seq, items=len(chunk), bytes=len(payload), file=name)
    return written


def scan_bridge_log(path: str, state: dict, *, now: int, cooldown: int = 86400) -> list[str]:
    """Return rejection reasons newly seen in the bridge log (offset-aware, rotation-safe)."""
    try:
        size = os.path.getsize(path)
    except FileNotFoundError:
        return []
    offset = int(state.get("log_offset") or 0)
    if size < offset:
        offset = 0
    if size == offset:
        return []
    with open(path, "rb") as handle:
        handle.seek(offset)
        chunk = handle.read(min(size - offset, 1_048_576))
    state["log_offset"] = offset + len(chunk)
    reasons: list[str] = []
    for raw in chunk.splitlines()[-2000:]:
        reason = rejection_reason(raw.decode("utf-8", "replace"))
        if reason is None:
            continue
        last = int(state["alerts"].get(reason, 0) or 0)
        if last and now - last < cooldown:
            continue
        state["alerts"][reason] = now
        reasons.append(reason)
    return reasons


class Bridge:
    """The loopback IMAP connection; every call is bounded by a socket timeout."""

    def __init__(self, host: str, port: int, address: str, password: str, timeout: float):
        self.host = host
        self.port = port
        self.address = address
        self.password = password
        self.timeout = timeout

    def connect(self) -> imaplib.IMAP4_SSL:
        # The bridge serves a self-signed certificate on loopback; there is no
        # name to verify and the connection never leaves the guest.
        context = ssl.create_default_context()
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        conn = imaplib.IMAP4_SSL(self.host, self.port, ssl_context=context, timeout=self.timeout)
        conn.login(self.address, self.password)
        return conn

    @staticmethod
    def folders(conn: imaplib.IMAP4_SSL) -> list[str]:
        typ, data = conn.list()
        if typ != "OK":
            raise MailError("IMAP LIST failed")
        names: list[str] = []
        for line in data or []:
            if not isinstance(line, (bytes, bytearray)):
                continue
            match = re.search(rb'"([^"]+)"\s*$', bytes(line)) or re.search(rb"([^ ]+)\s*$", bytes(line))
            if not match:
                continue
            name = match.group(1).decode("utf-8", "replace")
            if name and name.upper() not in {n.upper() for n in names}:
                names.append(name)
        return names

    @staticmethod
    def select(conn: imaplib.IMAP4_SSL, folder: str) -> tuple[int, int]:
        quoted = '"' + folder.replace("\\", "\\\\").replace('"', '\\"') + '"'
        typ, data = conn.select(quoted, readonly=True)
        if typ != "OK":
            raise MailError(f"IMAP SELECT {folder} failed")
        exists = 0
        if data and isinstance(data[0], (bytes, bytearray)):
            try:
                exists = int(bytes(data[0]))
            except ValueError:
                exists = 0
        typ, validity = conn.response("UIDVALIDITY")
        uidvalidity = 0
        if typ == "UIDVALIDITY" and validity and isinstance(validity[0], (bytes, bytearray)):
            try:
                uidvalidity = int(bytes(validity[0]))
            except ValueError:
                uidvalidity = 0
        return exists, uidvalidity

    @staticmethod
    def search_all(conn: imaplib.IMAP4_SSL) -> list[int]:
        typ, data = conn.uid("SEARCH", None, "ALL")
        if typ != "OK":
            raise MailError("IMAP UID SEARCH failed")
        return uid_list(data)

    @staticmethod
    def fetch(conn: imaplib.IMAP4_SSL, uid: int) -> bytes | None:
        typ, data = conn.uid("FETCH", str(uid), "(BODY.PEEK[])")
        if typ != "OK" or not data:
            return None
        for part in data:
            if isinstance(part, tuple) and len(part) >= 2 and isinstance(part[1], (bytes, bytearray)):
                return bytes(part[1])
        return None

    @staticmethod
    def has_idle(conn: imaplib.IMAP4_SSL) -> bool:
        return any(str(cap).upper() == "IDLE" for cap in (conn.capabilities or ()))

    @staticmethod
    def idle(conn: imaplib.IMAP4_SSL, seconds: int) -> bool:
        """Wait for one untagged event, then DONE; False when IDLE is unusable.

        imaplib has no public IDLE wrapper and `_simple_command` would block on
        the tagged completion the server never sends, so the tag is built,
        sent and reaped by hand: `+ idling`, one event or the timeout, then
        `DONE` and the tagged `OK`.
        """
        sock = getattr(conn, "sock", None)
        if sock is None:
            return False
        original = sock.gettimeout()
        tag = conn._new_tag()  # noqa: SLF001 - no public API for IDLE
        try:
            sock.settimeout(max(1.0, float(seconds)))
            conn.send(tag + b" IDLE\r\n")
            if not conn.readline().startswith(b"+"):
                return False
            deadline = time.monotonic() + seconds
            while time.monotonic() < deadline:
                line = conn.readline()
                if not line:
                    break
                if b"EXISTS" in line or b"RECENT" in line or b"EXPUNGE" in line:
                    break
            return True
        except (socket.timeout, OSError):
            return True
        finally:
            try:
                conn.send(b"DONE\r\n")
                # Drain until this tag's completion, or the next command would
                # read a stale response.
                while True:
                    line = conn.readline()
                    if not line or line.startswith(tag + b" "):
                        break
            except (OSError, imaplib.IMAP4.error):
                pass
            try:
                sock.settimeout(original)
            except OSError:
                pass


def folder_listing(conn: imaplib.IMAP4_SSL) -> list[tuple[str, str]]:
    """Every folder the bridge advertises, classified, with INBOX and Sent first."""
    names = Bridge.folders(conn)
    ordered = [n for n in names if folder_kind(n) == "inbox"]
    ordered += [n for n in names if folder_kind(n) == "sent"]
    ordered += [n for n in names if folder_kind(n) == "other"]
    return [(name, folder_kind(name)) for name in ordered]


def collect_folder(
    conn: imaplib.IMAP4_SSL,
    folder: str,
    state: dict,
    *,
    max_body_bytes: int,
    baseline: bool,
) -> tuple[list[dict], list[dict]]:
    """Return (mail items, sent alerts) for the folder's new UIDs."""
    _exists, uidvalidity = Bridge.select(conn, folder)
    present = Bridge.search_all(conn)
    fresh, action = plan_folder(state, folder, uidvalidity, present, baseline=baseline)
    if action != "delta":
        log(action, folder=folder, uidvalidity=uidvalidity, known=len(present))
    items: list[dict] = []
    alerts: list[dict] = []
    for uid in fresh:
        raw = Bridge.fetch(conn, uid)
        if raw is None:
            continue
        item = summarize(raw, folder, uid, max_body_bytes)
        items.append(item)
        if is_sent_folder(folder):
            alerts.append(sent_alert(item))
    if items:
        log("folder", folder=folder, new=len(items), uidvalidity=uidvalidity)
    return items, alerts


def run_once(
    args: argparse.Namespace,
    state: dict,
    *,
    bridge: Bridge,
    now: int,
    idle: bool = False,
) -> list[str]:
    """One collection pass over every wanted folder plus the bridge log."""
    written: list[str] = []
    conn = bridge.connect()
    try:
        listed = folder_listing(conn)
        wanted = {name.upper() for name in args.folders}
        selected = [
            (name, kind)
            for name, kind in listed
            if not wanted or name.upper() in wanted or kind in {"inbox", "sent"}
        ]
        if idle and selected and Bridge.has_idle(conn):
            Bridge.select(conn, selected[0][0])
            Bridge.idle(conn, args.idle_seconds)
        for name, _kind in selected:
            mail_items, sent_alerts = collect_folder(
                conn,
                name,
                state,
                max_body_bytes=args.max_body_bytes,
                baseline=args.baseline,
            )
            written += emit_batches(
                args.outbox,
                state,
                "batch",
                mail_items,
                max_items=args.max_items,
                max_bytes=args.max_batch_bytes,
            )
            written += emit_batches(
                args.outbox,
                state,
                "alert",
                sent_alerts,
                max_items=args.max_items,
                max_bytes=args.max_batch_bytes,
            )
            for alert in sent_alerts:
                log("sent-alert", folder=alert["folder"], uid=alert["uid"])
    finally:
        try:
            conn.logout()
        except (OSError, imaplib.IMAP4.error):
            pass

    for reason in scan_bridge_log(args.bridge_log, state, now=now, cooldown=args.alert_cooldown):
        log("client-rejection", reason=reason)
        written += emit_batches(
            args.outbox,
            state,
            "alert",
            [{"type": "client-rejection", "reason": reason}],
            max_items=1,
            max_bytes=args.max_batch_bytes,
        )
    return written


def read_secret(path: str) -> str | None:
    try:
        with open(path, encoding="utf-8") as handle:
            value = handle.read().strip()
    except FileNotFoundError:
        return None
    return value or None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="ingest-tuta-mail")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=1143)
    parser.add_argument("--address-file", default="/run/tutabridge/address")
    parser.add_argument("--password-file", default="/run/tutabridge/bridge-password")
    parser.add_argument("--outbox", default="/var/lib/ingest/outbox")
    parser.add_argument("--state", default="/var/lib/tutabridge/mail-state.json")
    parser.add_argument("--bridge-log", default="/var/lib/tutabridge/bridge.log")
    parser.add_argument(
        "--folders",
        nargs="*",
        default=["INBOX"],
        help="extra folders by name; INBOX and the Sent folder are always included",
    )
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--idle-seconds", type=int, default=IDLE_SECONDS)
    parser.add_argument("--poll-seconds", type=float, default=300.0)
    parser.add_argument("--max-items", type=int, default=50)
    parser.add_argument("--max-batch-bytes", type=int, default=policy.MAX_BATCH_BYTES // 2)
    parser.add_argument("--max-body-bytes", type=int, default=64 * 1024)
    parser.add_argument("--alert-cooldown", type=int, default=86400)
    parser.add_argument("--max-backoff", type=float, default=300.0)
    parser.add_argument("--no-baseline", dest="baseline", action="store_false")
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args(argv)

    state = load_state(args.state)
    backoff = 5.0
    while True:
        # Re-read every pass: a restaged session changes the bridge password and
        # must take effect without restarting the guest.
        address = read_secret(args.address_file)
        password = read_secret(args.password_file)
        if address is None or password is None:
            log("error", reason="loopback credentials missing; wait for tuta-session")
            if args.once:
                return 65
            time.sleep(backoff)
            backoff = min(backoff * 2, args.max_backoff)
            continue
        if not tuta_session.ADDRESS_RE.match(address):
            log("error", reason="staged address is not an email address")
            return 65
        bridge = Bridge(args.host, args.port, address, password, args.timeout)
        try:
            written = run_once(args, state, bridge=bridge, now=int(time.time()), idle=not args.once)
            write_state(args.state, state)
            backoff = 5.0
            log("idle", batches=len(written))
        except (MailError, OSError, imaplib.IMAP4.error, ssl.SSLError) as exc:
            log("retry", reason=str(exc), backoff_s=backoff)
            time.sleep(backoff)
            backoff = min(backoff * 2, args.max_backoff)
            continue
        if args.once:
            return 0
        time.sleep(args.poll_seconds)


if __name__ == "__main__":
    sys.exit(main())
