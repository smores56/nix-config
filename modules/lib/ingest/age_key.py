"""Publish Kanbei's age recipient to the host over a schema-locked vsock port.

Kanbei dials host CID 2 on port 7100; Firecracker forwards that connection to
the AF_UNIX socket at `/var/lib/microvms/kanbei/notify.vsock_7100`, which this
unit listens on. The guest writes one `age1...` line and reads `OK\\n`; every
other line is refused and the previous recipient is kept. The host file is
written atomically, root-only, and the writers block until it exists.
"""

from __future__ import annotations

import argparse
import grp
import json
import os
import socket
import sys
import tempfile
from datetime import datetime, timezone

import policy

MAX_LINE = 256


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


def serve(uds: str, out: str, group: str) -> None:
    directory = os.path.dirname(uds)
    if not os.path.isdir(directory):
        raise SystemExit(f"ingest-age-key: {directory} is missing; the Kanbei guest is not installed")
    try:
        os.unlink(uds)
    except FileNotFoundError:
        pass
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(uds)
    # Firecracker (microvm:kvm) dials this socket to forward the guest connection.
    os.chmod(uds, 0o660)
    if group:
        os.chown(uds, 0, grp.getgrnam(group).gr_gid)
    server.listen(4)
    log("listen", path=uds)
    while True:
        conn, _ = server.accept()
        with conn:
            conn.settimeout(10)
            data = b""
            while b"\n" not in data and len(data) < MAX_LINE:
                chunk = conn.recv(MAX_LINE)
                if not chunk:
                    break
                data += chunk
            try:
                lines = [line for line in data.decode("utf-8", "strict").splitlines() if line.strip()]
                if len(lines) != 1:
                    raise policy.PolicyError("expected exactly one recipient line")
                recipient = policy.validate_age_recipient(lines[0])
            except (policy.PolicyError, UnicodeDecodeError) as exc:
                log("reject", reason=str(exc), bytes=len(data))
                conn.sendall(b"ERR\n")
                continue
            write_recipient(out, recipient)
            log("published", path=out, recipient_len=len(recipient))
            conn.sendall(b"OK\n")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="ingest-age-key")
    parser.add_argument("--uds", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--group", default="kvm", help="group allowed to connect (Firecracker)")
    args = parser.parse_args(argv)
    serve(args.uds, args.out, args.group)
    return 0


if __name__ == "__main__":
    sys.exit(main())
