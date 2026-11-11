#!/usr/bin/env python3
"""Host side of the Kanbei ``kanbei-cert`` channel.

Listens on AF_VSOCK (host CID, port 10001). A guest asks with a CSR for the fixed CN; this
process validates it against the policy in ``vsock.py``, verifies its self-signature, asks
Lego for a DNS-01 certificate for that CSR (the Cloudflare API token arrives as a systemd
credential), checks that the leaf carries the CSR's public key and the fixed name, and
returns the chain. No private key is ever created or stored on the host.

Lego is invoked with ``--csr`` so it signs the guest's key instead of making its own; only
the account lives under ``--state-dir`` (the previous certificate file is removed first so
Lego always issues for the new CSR).
"""

from __future__ import annotations

import argparse
import os
import socket
import subprocess
import sys
import tempfile
import threading

import vsock

VMADDR_CID_ANY = 0xFFFFFFFF
HOST_VSOCK_PORT = 10001


class Signer:
    def __init__(
        self,
        *,
        lego: str,
        openssl: str,
        state_dir: str,
        email: str,
        token_file: str,
        server: str = "https://acme-v02.api.letsencrypt.org/directory",
    ) -> None:
        self.lego = lego
        self.openssl = openssl
        self.state_dir = state_dir
        self.email = email
        self.token_file = token_file
        self.server = server
        self.lock = threading.Lock()

    def _token(self) -> str:
        with open(self.token_file, "r", encoding="utf-8") as handle:
            token = handle.read().strip()
        if not token:
            raise RuntimeError("cloudflare token credential is empty")
        return token

    def _verify_csr_signature(self, csr_path: str) -> None:
        result = subprocess.run(
            [self.openssl, "req", "-in", csr_path, "-noout", "-verify"],
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        if result.returncode != 0:
            raise RuntimeError("CSR self-signature did not verify")

    def issue(self, csr_pem: str) -> dict:
        expected = vsock.csr_spki(csr_pem)
        lego_path = os.path.join(self.state_dir, "lego")
        certificates = os.path.join(lego_path, "certificates")
        os.makedirs(certificates, mode=0o700, exist_ok=True)
        with self.lock, tempfile.TemporaryDirectory(dir=self.state_dir) as work:
            csr_path = os.path.join(work, "request.csr")
            with open(csr_path, "w", encoding="utf-8") as handle:
                handle.write(csr_pem.strip() + "\n")
            self._verify_csr_signature(csr_path)
            # Lego's `run` installs beside the account; drop the previous issuance for this
            # name so the new CSR is the one signed.
            for name in os.listdir(certificates):
                if name.startswith(vsock.FIXED_CN):
                    os.unlink(os.path.join(certificates, name))
            environment = os.environ.copy()
            environment["CLOUDFLARE_DNS_API_TOKEN"] = self._token()
            command = [
                self.lego,
                "--accept-tos",
                "--email",
                self.email,
                "--server",
                self.server,
                "--path",
                lego_path,
                "--dns",
                "cloudflare",
                "--domains",
                vsock.FIXED_CN,
                "--csr",
                csr_path,
                "run",
            ]
            result = subprocess.run(
                command,
                capture_output=True,
                text=True,
                timeout=600,
                check=False,
                env=environment,
            )
            if result.returncode != 0:
                detail = (result.stderr or result.stdout).strip().splitlines()
                raise RuntimeError(f"lego failed: {detail[-1] if detail else 'no output'}")
            cert_file = os.path.join(certificates, f"{vsock.FIXED_CN}.crt")
            with open(cert_file, "r", encoding="utf-8") as handle:
                chain = handle.read()

        info = vsock.validate_cert(vsock.split_chain(chain)[0], expected_spki=expected)
        return vsock.success(chain, info["not_after"])


def respond(signer: Signer, obj: dict) -> dict:
    try:
        csr = vsock.parse_request(obj)
        vsock.validate_csr(csr)
        return signer.issue(csr)
    except (vsock.FrameError, vsock.SchemaError, vsock.CsrError, vsock.CertError) as exc:
        return vsock.error(str(exc))
    except (RuntimeError, subprocess.SubprocessError) as exc:
        return vsock.error(str(exc))


def handle_connection(conn: socket.socket, signer: Signer) -> None:
    try:
        conn.settimeout(120)
        request = vsock.read_frame(conn)
        vsock.write_frame(conn, respond(signer, request))
    except (vsock.FrameError, OSError) as exc:
        try:
            vsock.write_frame(conn, vsock.error(f"channel error: {exc}"))
        except OSError:
            pass
    finally:
        try:
            conn.close()
        except OSError:
            pass


def serve(signer: Signer, port: int, stop: threading.Event | None = None) -> None:
    listener = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    listener.bind((VMADDR_CID_ANY, port))
    listener.listen(8)
    listener.settimeout(0.5)
    try:
        while stop is None or not stop.is_set():
            try:
                conn, _peer = listener.accept()
            except TimeoutError:
                continue
            except OSError:
                if stop is not None and stop.is_set():
                    return
                raise
            # One issuance at a time: the signer's lock serialises the ACME client anyway, and a
            # short queue keeps a compromised guest from fanning out ACME requests.
            handle_connection(conn, signer)
    finally:
        listener.close()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=HOST_VSOCK_PORT)
    parser.add_argument("--state-dir", default="/var/lib/kanbei-acme")
    parser.add_argument("--email", required=True)
    parser.add_argument("--lego", required=True)
    parser.add_argument("--openssl", required=True)
    parser.add_argument("--token-file", required=True)
    parser.add_argument("--server", default="https://acme-v02.api.letsencrypt.org/directory")
    args = parser.parse_args(argv)

    os.makedirs(args.state_dir, mode=0o700, exist_ok=True)
    signer = Signer(
        lego=args.lego,
        openssl=args.openssl,
        state_dir=args.state_dir,
        email=args.email,
        token_file=args.token_file,
        server=args.server,
    )
    print(f"kanbei-acme: listening on vsock port {args.port}", file=sys.stderr)
    serve(signer, args.port)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
