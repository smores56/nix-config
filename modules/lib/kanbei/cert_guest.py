#!/usr/bin/env python3
"""Guest side of the Kanbei ``kanbei-cert`` channel.

Runs in the guest, as root, on boot and from a daily timer. If the installed certificate is
still valid for more than ``--renew-days`` and carries the fixed name, it exits without
touching the channel. Otherwise it creates a P-256 key and CSR for ``kanbei.sammohr.dev``,
sends the CSR to the host's ACME responder over AF_VSOCK, validates the returned chain (fixed
CN/SAN and the same public key), writes the key and certificate 0400 root, and restarts the
TLS frontend so the new certificate is served.

Only the CSR crosses the boundary. The private key is generated here and never leaves. The
first line on the channel is the shared relay token from the guest's read-only
``kanbei-secrets`` share; the host responder refuses the connection without it.
"""

from __future__ import annotations

import argparse
import os
import shutil
import socket
import subprocess
import sys
import tempfile

import relay_auth
import vsock

VMADDR_CID_HOST = 2
HOST_VSOCK_PORT = 10001


def certificate_is_fresh(cert: str, openssl: str, renew_days: int) -> bool:
    if not os.path.isfile(cert):
        return False
    result = subprocess.run(
        [openssl, "x509", "-checkend", str(renew_days * 86400), "-noout", "-in", cert],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        return False
    with open(cert, "r", encoding="utf-8") as handle:
        try:
            # cert.pem holds the leaf plus intermediates; the leaf is the one to check.
            vsock.validate_cert(vsock.split_chain(handle.read())[0])
        except (vsock.CertError, ValueError):
            return False
    return True


def make_csr(openssl: str, directory: str) -> tuple[str, str]:
    key_path = os.path.join(directory, "key.pem")
    csr_path = os.path.join(directory, "request.csr")
    subprocess.run(
        [
            openssl,
            "req",
            "-new",
            "-newkey",
            "ec",
            "-pkeyopt",
            "ec_paramgen_curve:prime256v1",
            "-nodes",
            "-keyout",
            key_path,
            "-out",
            csr_path,
            "-subj",
            f"/CN={vsock.FIXED_CN}",
            "-addext",
            f"subjectAltName=DNS:{vsock.FIXED_CN}",
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    with open(key_path, "r", encoding="utf-8") as handle:
        key = handle.read()
    with open(csr_path, "r", encoding="utf-8") as handle:
        csr = handle.read()
    os.unlink(key_path)
    os.unlink(csr_path)
    return key, csr


def exchange(cid: int, port: int, csr: str, token: bytes) -> dict:
    with socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM) as conn:
        conn.settimeout(900)
        conn.connect((cid, port))
        conn.sendall(relay_auth.encode(token))
        vsock.write_frame(conn, {"v": vsock.PROTOCOL_VERSION, "cn": vsock.FIXED_CN, "csr": csr})
        return vsock.parse_response(vsock.read_frame(conn))


def install(state_dir: str, key: str, chain: str) -> tuple[str, str]:
    os.makedirs(state_dir, mode=0o700, exist_ok=True)
    os.chmod(state_dir, 0o700)
    key_path = os.path.join(state_dir, "key.pem")
    cert_path = os.path.join(state_dir, "cert.pem")
    for path, data in ((key_path, key), (cert_path, chain)):
        temporary = f"{path}.new"
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o400)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(data)
        os.replace(temporary, path)
    return key_path, cert_path


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", default="/var/lib/kanbei/tls")
    parser.add_argument("--host-vsock-cid", type=int, default=VMADDR_CID_HOST)
    parser.add_argument("--host-vsock-port", type=int, default=HOST_VSOCK_PORT)
    parser.add_argument("--renew-days", type=int, default=30)
    parser.add_argument("--openssl", required=True)
    parser.add_argument("--reload-unit", default="kanbei-ui.service")
    parser.add_argument(
        "--token-file",
        default="/run/kanbei-secrets/relay-token",
        help="shared relay token on the read-only kanbei-secrets share",
    )
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args(argv)

    try:
        token = relay_auth.read_token(args.token_file)
    except relay_auth.AuthError as exc:
        print(f"kanbei-cert: {exc}", file=sys.stderr)
        return 1

    cert_path = os.path.join(args.state_dir, "cert.pem")
    if not args.force and certificate_is_fresh(cert_path, args.openssl, args.renew_days):
        print(f"kanbei-cert: {cert_path} is fresh; nothing to do", file=sys.stderr)
        return 0

    scratch = tempfile.mkdtemp(prefix="kanbei-cert.")
    try:
        key, csr = make_csr(args.openssl, scratch)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)

    try:
        response = exchange(args.host_vsock_cid, args.host_vsock_port, csr, token)
        vsock.validate_cert(
            vsock.split_chain(response["chain"])[0],
            expected_spki=vsock.csr_spki(csr),
        )
    except (OSError, vsock.FrameError, vsock.SchemaError, vsock.CertError) as exc:
        print(f"kanbei-cert: certificate request failed: {exc}", file=sys.stderr)
        return 1

    install(args.state_dir, key, response["chain"])
    print(f"kanbei-cert: installed {cert_path} (not after {response['not_after']})", file=sys.stderr)
    if args.reload_unit:
        subprocess.run(["systemctl", "try-restart", args.reload_unit], check=False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
