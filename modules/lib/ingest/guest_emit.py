"""Guest-side shipper for the ingest plane.

Listens on the guest's AF_VSOCK port, sends every NDJSON batch file in
`/var/lib/ingest/outbox` as one length-prefixed frame, and moves a file to
`sent/` only after the host writer's `{"ack": seq}` line. Invalid files move to
`rejected/` without touching the wire.

The host side is `writer.py`; both import the same `policy` module.
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import sys
import time
from datetime import datetime, timezone

import policy

VMADDR_CID_ANY = 0xFFFFFFFF


def log(event: str, **fields: object) -> None:
    record = {"ts": datetime.now(timezone.utc).isoformat(timespec="seconds"), "unit": "ingest-emit", "event": event}
    record.update(fields)
    print(json.dumps(record, sort_keys=True), flush=True)


def secret_status(path: str) -> None:
    try:
        st = os.stat(path)
    except FileNotFoundError:
        log("secret", path=path, present=False)
        return
    log("secret", path=path, present=True, mode=oct(st.st_mode & 0o777), bytes=st.st_size)


def ship(conn: socket.socket, source: str, outbox: str) -> None:
    sent_dir = os.path.join(os.path.dirname(outbox), "sent")
    rejected_dir = os.path.join(os.path.dirname(outbox), "rejected")
    os.makedirs(sent_dir, exist_ok=True)
    os.makedirs(rejected_dir, exist_ok=True)
    conn.settimeout(15)
    names = sorted(name for name in os.listdir(outbox) if name.endswith(".json"))
    if not names:
        log("idle", source=source)
        return
    for index, name in enumerate(names):
        path = os.path.join(outbox, name)
        try:
            with open(path, "rb") as handle:
                payload = handle.read()
        except FileNotFoundError:
            continue
        try:
            batch = policy.validate_batch(payload, source)
        except policy.PolicyError as exc:
            log("reject", source=source, file=name, reason=str(exc))
            os.replace(path, os.path.join(rejected_dir, name))
            continue
        conn.sendall(policy.encode_frame(payload))
        ack_data = b""
        while not ack_data.endswith(b"\n") and len(ack_data) < 256:
            chunk = conn.recv(256)
            if not chunk:
                raise ConnectionError("writer closed before ack")
            ack_data += chunk
        try:
            ack = json.loads(ack_data.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise ConnectionError(f"malformed ack: {ack_data!r}") from exc
        expected = batch.get("seq", index)
        if not isinstance(ack, dict) or ack.get("ack") != expected:
            raise ConnectionError(f"ack mismatch: expected {expected}, got {ack!r}")
        os.replace(path, os.path.join(sent_dir, name))
        log("sent", source=source, file=name, bytes=len(payload), seq=expected)


def serve(source: str, port: int, outbox: str, secret: str) -> None:
    secret_status(secret)
    server = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((VMADDR_CID_ANY, port))
    server.listen(4)
    log("listen", source=source, port=port, outbox=outbox)
    while True:
        conn, _ = server.accept()
        with conn:
            try:
                ship(conn, source, outbox)
            except (ConnectionError, OSError, policy.PolicyError) as exc:
                log("error", source=source, reason=str(exc))
                time.sleep(1)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="ingest-emit")
    parser.add_argument("--source", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--outbox", required=True)
    parser.add_argument("--secret", default="/run/ingest-secret/env")
    args = parser.parse_args(argv)
    serve(args.source, args.port, args.outbox, args.secret)
    return 0


if __name__ == "__main__":
    sys.exit(main())
