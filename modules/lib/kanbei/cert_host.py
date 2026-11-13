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

Two gates protect the responder: the connection must come from the kanbei guest CID and its
first line must carry the shared root-only relay token (``relay_auth``), and issuance is
rate-limited to one certificate per ``--min-interval`` (default 6 h) through a persistent
marker in the state directory, so a compromised guest cannot fan out ACME requests.
"""

from __future__ import annotations

import argparse
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time

import relay_auth
import vsock

VMADDR_CID_ANY = 0xFFFFFFFF
HOST_VSOCK_PORT = 10001
KANBEI_CID = 4
MIN_ISSUE_INTERVAL = 6 * 3600


def marker_epoch(path: str) -> int:
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return int(handle.read().strip())
    except (FileNotFoundError, OSError, ValueError):
        return 0


def rate_limited(path: str, now: int, min_interval: int = MIN_ISSUE_INTERVAL) -> bool:
    """True while the last successful issuance is newer than ``min_interval``."""
    last = marker_epoch(path)
    return last > 0 and 0 <= now - last < min_interval


def record_issue(path: str, now: int) -> None:
    directory = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".issue-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(f"{now}\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


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
        min_interval: int = MIN_ISSUE_INTERVAL,
        clock=time.time,
    ) -> None:
        self.lego = lego
        self.openssl = openssl
        self.state_dir = state_dir
        self.email = email
        self.token_file = token_file
        self.server = server
        self.min_interval = min_interval
        self.clock = clock
        self.marker = os.path.join(state_dir, "last-issue")
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
            now = int(self.clock())
            if rate_limited(self.marker, now, self.min_interval):
                raise RuntimeError(
                    f"issuance rate limited: one certificate per {self.min_interval} s"
                )
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
        record_issue(self.marker, now)
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


def handle_connection(
    conn: socket.socket, signer: Signer, token: bytes, expected_cid: int = KANBEI_CID
) -> None:
    try:
        conn.settimeout(120)
        relay_auth.require_peer(conn, expected_cid)
        relay_auth.verify(conn, token)
        request = vsock.read_frame(conn)
        vsock.write_frame(conn, respond(signer, request))
    except relay_auth.AuthError as exc:
        try:
            vsock.write_frame(conn, vsock.error(f"channel error: {exc}"))
        except OSError:
            pass
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


def serve(
    signer: Signer,
    port: int,
    token: bytes,
    expected_cid: int = KANBEI_CID,
    stop: threading.Event | None = None,
) -> None:
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
            handle_connection(conn, signer, token, expected_cid)
    finally:
        listener.close()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=HOST_VSOCK_PORT)
    parser.add_argument("--state-dir", default="/var/lib/kanbei-acme")
    parser.add_argument("--email", required=True)
    parser.add_argument("--lego", required=True)
    parser.add_argument("--openssl", required=True)
    parser.add_argument("--token-file", required=True, help="shared root-only relay token")
    parser.add_argument(
        "--dns-token-file", required=True, help="Cloudflare DNS-01 API token credential"
    )
    parser.add_argument("--peer-cid", type=int, default=KANBEI_CID)
    parser.add_argument("--min-interval", type=int, default=MIN_ISSUE_INTERVAL)
    parser.add_argument("--server", default="https://acme-v02.api.letsencrypt.org/directory")
    args = parser.parse_args(argv)

    os.makedirs(args.state_dir, mode=0o700, exist_ok=True)
    try:
        token = relay_auth.read_token(args.token_file)
    except relay_auth.AuthError as exc:
        print(f"kanbei-acme: {exc}", file=sys.stderr)
        return 2
    signer = Signer(
        lego=args.lego,
        openssl=args.openssl,
        state_dir=args.state_dir,
        email=args.email,
        token_file=args.dns_token_file,
        server=args.server,
        min_interval=args.min_interval,
    )
    print(f"kanbei-acme: listening on vsock port {args.port}", file=sys.stderr)
    serve(signer, args.port, token, args.peer_cid)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
