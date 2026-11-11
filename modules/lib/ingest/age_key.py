"""Publish Kanbei's age recipient to the host over a schema-locked vsock port.

Kanbei dials host CID 2 on port 7100; this unit listens on host AF_VSOCK directly (the
kanbei guest is qemu, so there is no Firecracker UDS to forward through). The connection
must come from the kanbei guest CID and its first line must carry the shared root-only
relay token. The guest then writes one `age1...` line and reads `OK\\n`; every other line
is refused and the previous recipient is kept. The host file is written atomically,
root-only, and the writers block until it exists.
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import sys
import tempfile
from datetime import datetime, timezone

import policy
import relay_auth

MAX_LINE = 256
VMADDR_CID_ANY = 0xFFFFFFFF
KANBEI_CID = 4


def log(event: str, **fields: object) -> None:
    record = {"ts": datetime.now(timezone.utc).isoformat(timespec="seconds"), "unit": "ingest-age-key", "event": event}
    record.update(fields)
    print(json.dumps(record, sort_keys=True), flush=True)


def write_recipient(path: str, recipient: str) -> None:
    directory = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".age-recipient.", suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(recipient + "\n")
    os.chmod(tmp, 0o400)
    os.replace(tmp, path)


def read_line(conn: socket.socket, max_line: int = MAX_LINE) -> bytes:
    data = b""
    while b"\n" not in data and len(data) < max_line:
        chunk = conn.recv(max_line - len(data))
        if not chunk:
            break
        data += chunk
    return data.split(b"\n", 1)[0]


def handle(conn: socket.socket, out: str, token: bytes, expected_cid: int | None = None) -> None:
    """Serve one connection: peer gate, token gate, then exactly one recipient line."""
    conn.settimeout(10)
    try:
        if expected_cid is not None:
            relay_auth.require_peer(conn, expected_cid)
        relay_auth.verify(conn, token)
    except relay_auth.AuthError as exc:
        log("reject", reason=str(exc))
        try:
            conn.sendall(b"ERR\n")
        except OSError:
            pass
        return
    data = read_line(conn)
    try:
        lines = [line for line in data.decode("utf-8", "strict").splitlines() if line.strip()]
        if len(lines) != 1:
            raise policy.PolicyError("expected exactly one recipient line")
        recipient = policy.validate_age_recipient(lines[0])
    except (policy.PolicyError, UnicodeDecodeError) as exc:
        log("reject", reason=str(exc), bytes=len(data))
        try:
            conn.sendall(b"ERR\n")
        except OSError:
            pass
        return
    write_recipient(out, recipient)
    log("published", path=out, recipient_len=len(recipient))
    conn.sendall(b"OK\n")


def serve(port: int, out: str, token: bytes, expected_cid: int = KANBEI_CID) -> None:
    server = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    server.bind((VMADDR_CID_ANY, port))
    server.listen(4)
    log("listen", port=port, peer_cid=expected_cid)
    while True:
        conn, peer = server.accept()
        with conn:
            log("connection", peer_cid=peer[0])
            handle(conn, out, token, expected_cid)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="ingest-age-key")
    parser.add_argument("--port", type=int, required=True, help="host AF_VSOCK port")
    parser.add_argument("--out", required=True)
    parser.add_argument("--token-file", required=True, help="root-only relay token")
    parser.add_argument(
        "--peer-cid", type=int, default=KANBEI_CID, help="the only guest CID allowed"
    )
    args = parser.parse_args(argv)
    try:
        token = relay_auth.read_token(args.token_file)
    except relay_auth.AuthError as exc:
        print(f"ingest-age-key: {exc}", file=sys.stderr)
        return 2
    serve(args.port, args.out, token, args.peer_cid)
    return 0


if __name__ == "__main__":
    sys.exit(main())
