"""Host writer: connect to one ingest guest's Firecracker vsock, validate batches,
age-encrypt them to Kanbei's recipient and drop them in the read-only inbox share.

Wire: the Firecracker UDS is `<vmStateDir>/notify.vsock`; the host sends
`CONNECT <port>\\n` and expects `OK <assigned>\\n`, then a stream of 4-byte
big-endian length-prefixed UTF-8 JSON batches (one per frame). The guest waits for
a `{"ack": <seq>}\\n` line before it moves a batch out of its outbox.
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from typing import Callable

import policy

AGE = "age"


def log(event: str, **fields: object) -> None:
    record = {"ts": datetime.now(timezone.utc).isoformat(timespec="seconds"), "unit": "ingest-writer", "event": event}
    record.update(fields)
    print(json.dumps(record, sort_keys=True), flush=True)


def fail(message: str, code: int = 65) -> int:
    log("error", message=message)
    return code


def wait_for_recipient(path: str, poll: float = 2.0) -> str:
    """Block until Kanbei has published a valid recipient; refuse malformed content."""
    while True:
        try:
            with open(path, encoding="utf-8") as handle:
                recipient = policy.validate_age_recipient(handle.read())
            log("recipient", path=path, recipient_len=len(recipient))
            return recipient
        except FileNotFoundError:
            log("waiting", reason="recipient missing", path=path)
            time.sleep(poll)
        except policy.PolicyError as exc:
            raise SystemExit(fail(f"invalid age recipient in {path}: {exc}"))


def read_reply_line(sock: socket.socket, max_line: int = 64) -> str:
    """Read exactly the `OK <port>` line, never a byte of the frame behind it.

    A guest with a queued batch writes the handshake and the first frame back to
    back; one recv() coalesces them, and reading 64 bytes then judging the whole
    buffer as "the reply" rejected a valid handshake.
    """
    line = bytearray()
    while len(line) < max_line:
        chunk = sock.recv(1)
        if not chunk:
            break
        if chunk == b"\n":
            return bytes(line).decode("ascii", "replace")
        line += chunk
    raise ConnectionError(f"vsock reply line is longer than {max_line} bytes")


def connect_vsock(uds_path: str, port: int, timeout: float = 30.0) -> socket.socket:
    deadline = time.monotonic() + timeout
    while True:
        if os.path.exists(uds_path):
            try:
                sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                sock.settimeout(30)
                sock.connect(uds_path)
                sock.sendall(f"CONNECT {port}\n".encode())
                try:
                    text = read_reply_line(sock)
                except ConnectionError:
                    sock.close()
                    raise
                if not text.startswith("OK ") or not text[3:].strip().isdigit():
                    sock.close()
                    raise ConnectionError(f"vsock handshake refused: {text!r}")
                log("connected", uds=uds_path, port=port, host_port=int(text[3:].strip()))
                sock.settimeout(None)
                return sock
            except (ConnectionError, OSError) as exc:
                log("retry", reason=f"vsock connect: {exc}")
        else:
            log("waiting", reason="vsock socket missing", path=uds_path)
        if time.monotonic() > deadline:
            raise TimeoutError(f"{uds_path} did not answer CONNECT {port}")
        time.sleep(2.0)


def encrypt_to(recipient: str, payload: bytes, tmpdir: str) -> str:
    fd, tmp = tempfile.mkstemp(dir=tmpdir, prefix=".batch-", suffix=".age.tmp")
    try:
        with os.fdopen(fd, "wb") as out:
            proc = subprocess.run(
                [AGE, "--encrypt", "-r", recipient],
                input=payload,
                stdout=out,
                stderr=subprocess.PIPE,
                check=False,
            )
        if proc.returncode != 0:
            raise RuntimeError(f"age failed: {proc.stderr.decode('utf-8', 'replace').strip()}")
        if os.path.getsize(tmp) <= len(payload):
            raise RuntimeError("age output is not larger than its plaintext")
        return tmp
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


def page(source: str, run: Callable[..., object] = subprocess.run) -> None:
    """Start the source's failure-notification unit for an `alert` batch."""
    run(
        ["systemctl", "start", "--no-block", f"ntfy-publish@ingest-writer-{source}.service"],
        check=False,
    )


def write_batch(inbox: str, source: str, seq: int, recipient: str, payload: bytes) -> str:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    name = f"{source}-{stamp}-{seq:06d}.age"
    tmp = encrypt_to(recipient, payload, inbox)
    target = os.path.join(inbox, name)
    # 0600 root: only Kanbei's inbox reader (guest root, via the read-only share) may read
    # a batch; the inbox directory is 0750 root.
    os.chmod(tmp, 0o600)
    os.replace(tmp, target)
    return target


def record_state(state_dir: str, source: str, count: int, target: str) -> None:
    now = datetime.now(timezone.utc)
    record = {
        "source": source,
        "last_ok": now.isoformat(timespec="seconds"),
        "epoch": int(now.timestamp()),
        "batches": count,
        "last_file": os.path.basename(target),
    }
    fd, tmp = tempfile.mkstemp(dir=state_dir, prefix=f".{source}.", suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(record, handle, sort_keys=True)
    os.chmod(tmp, 0o600)
    os.replace(tmp, os.path.join(state_dir, f"{source}.last-ok"))


def session(args: argparse.Namespace, recipient: str, run: Callable[..., object] = subprocess.run) -> int:
    sock = connect_vsock(args.vsock, args.guest_port)
    decoder = policy.FrameDecoder(policy.MAX_BATCH_BYTES)
    batches = 0
    with sock:
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            for payload in decoder.feed(chunk):
                try:
                    batch = policy.validate_batch(payload, args.source)
                except policy.PolicyError as exc:
                    log("reject", source=args.source, reason=str(exc), bytes=len(payload))
                    return fail(f"rejected batch from {args.source}: {exc}")
                seq = int(batch.get("seq", batches))
                target = write_batch(args.inbox, args.source, seq, recipient, payload)
                record_state(args.state_dir, args.source, batches + 1, target)
                if batch["kind"] == "alert":
                    # The guest owns no mail path; the host turns the alert batch
                    # into the same page a failed unit raises.
                    page(args.source, run)
                    log("alert", source=args.source, seq=seq, items=len(batch["items"]))
                sock.sendall(json.dumps({"ack": seq}).encode() + b"\n")
                batches += 1
                log("batch", source=args.source, seq=seq, bytes=len(payload), file=os.path.basename(target))
    log("session-end", source=args.source, batches=batches)
    if batches == 0:
        return 4
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="ingest-writer")
    parser.add_argument("--source", required=True, help="source id (also validated in every batch)")
    parser.add_argument("--vsock", required=True, help="Firecracker notify.vsock path")
    parser.add_argument("--guest-port", type=int, required=True)
    parser.add_argument("--recipient-file", required=True)
    parser.add_argument("--inbox", required=True)
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--policy", help="policy file (accepted for the unit contract; the source is explicit)")
    parser.add_argument("--once", action="store_true", help="one connection, then exit")
    args = parser.parse_args(argv)

    if args.policy and not os.path.isfile(args.policy):
        return fail(f"policy file missing: {args.policy}")
    for directory in (args.inbox, args.state_dir):
        if not os.path.isdir(directory):
            return fail(f"directory missing: {directory}")

    recipient = wait_for_recipient(args.recipient_file)
    if args.once:
        try:
            return session(args, recipient)
        except (TimeoutError, OSError) as exc:
            return fail(str(exc), 4)

    while True:
        try:
            log("session-start", source=args.source, vsock=args.vsock)
            code = session(args, recipient)
            if code not in (0, 4):
                return code
            time.sleep(2.0)
        except (TimeoutError, OSError, ConnectionError) as exc:
            log("retry", source=args.source, reason=str(exc))
            time.sleep(2.0)


if __name__ == "__main__":
    sys.exit(main())
