"""Root-only, hardware-gated proof for the ingest plane.

Run as root on smortress (or through /run/wrappers/bin/sudo):

    /run/wrappers/bin/sudo /run/current-system/sw/bin/kanbei-ingest-verify

It stops the production search writer, reboots the `search` guest so its test
batch is seeded again, and then proves:

  a. one batch round-trips through ingest-writer and decrypts with the test age
     identity (the same framing/encryption path as Kanbei's published key);
  b. a non-allowlisted DNS name and a non-matching SNI are refused; and
  c. the guest cannot egress directly: its own probe logs INGEST-EGRESS-DROPPED
     and the per-tap forward chain ends in DROP with no non-conntrack ACCEPT.

It restores the writer and leaves the guest running. Nothing here runs in CI;
the eval checks cover the policy validators instead.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import shutil
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path

GUEST = "search"
SOURCE = "search"
GUEST_PORT = 7014
VSOCK = "/var/lib/microvms/search/notify.vsock"
POLICY = "/etc/kanbei-ingest/policy.json"
INBOX = "/var/lib/data/inbox"
CHAIN = "ingest-search-fwd"


def say(message: str) -> None:
    print(f"kanbei-ingest-verify: {message}", flush=True)


def fail(message: str) -> None:
    print(f"kanbei-ingest-verify: FAIL: {message}", file=sys.stderr, flush=True)
    raise SystemExit(1)


def run(cmd: list[str], **kwargs: object) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, check=False, capture_output=True, text=True, **kwargs)


def require_root() -> None:
    if os.geteuid() != 0:
        print(
            "kanbei-ingest-verify: root required; run "
            "/run/wrappers/bin/sudo /run/current-system/sw/bin/kanbei-ingest-verify",
            file=sys.stderr,
        )
        raise SystemExit(2)


def require_hardware() -> None:
    missing = [path for path in ("/dev/kvm", "/dev/net/tun", "/dev/vhost-vsock") if not os.path.exists(path)]
    if missing:
        print(
            f"kanbei-ingest-verify: hardware-gated: missing {', '.join(missing)}; "
            "this host cannot boot a Firecracker guest",
            file=sys.stderr,
        )
        raise SystemExit(3)


def journal(unit: str, since: str) -> str:
    proc = run(["journalctl", "-u", unit, "--since", since, "--no-pager", "-o", "cat"])
    return proc.stdout


def wait_for(predicate, timeout: float, interval: float = 1.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(interval)
    return False


def free_port() -> int:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


def age_keypair(directory: Path) -> tuple[Path, str]:
    identity = directory / "identity"
    gen = run(["age-keygen", "-o", str(identity)])
    if gen.returncode != 0:
        fail(f"age-keygen failed: {gen.stderr.strip()}")
    pub = run(["age-keygen", "-y", str(identity)])
    if pub.returncode != 0:
        fail(f"age-keygen -y failed: {pub.stderr.strip()}")
    return identity, pub.stdout.strip()


def dns_query(name: str, timeout: float = 3.0) -> int:
    qname = b"".join(bytes([len(label)]) + label.encode() for label in name.split(".")) + b"\x00"
    ident = int.from_bytes(os.urandom(2), "big")
    message = struct.pack(">HHHHHH", ident, 0x0100, 1, 0, 0, 0) + qname + struct.pack(">HH", 1, 1)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    try:
        sock.sendto(message, address := ("127.0.0.1", DNS_PORT[0]))
        reply, _ = sock.recvfrom(4096)
        if len(reply) < 12:
            fail(f"short DNS reply for {name}")
        _rid, flags, _qd, _an, _ns, _ar = struct.unpack(">HHHHHH", reply[:12])
        return flags & 0xF
    except socket.timeout:
        fail(f"resolver did not answer for {name}")
    finally:
        sock.close()


DNS_PORT = [0]


def client_hello(sni: str) -> bytes:
    incoming = ssl.MemoryBIO()
    outgoing = ssl.MemoryBIO()
    context = ssl.create_default_context()
    obj = context.wrap_bio(incoming, outgoing, server_hostname=sni)
    try:
        obj.do_handshake()
    except ssl.SSLWantReadError:
        pass
    return outgoing.read()


def check_round_trip(directory: Path) -> None:
    identity, recipient = age_keypair(directory)
    recipient_file = directory / "recipient"
    recipient_file.write_text(recipient + "\n")
    os.chmod(recipient_file, 0o400)
    inbox = directory / "inbox"
    state = directory / "state"
    inbox.mkdir(mode=0o700)
    state.mkdir(mode=0o700)

    writer = shutil.which("ingest-writer")
    if writer is None:
        fail("ingest-writer is not on PATH")
    try:
        proc = run(
            [
                writer,
                "--policy",
                POLICY,
                "--source",
                SOURCE,
                "--vsock",
                VSOCK,
                "--guest-port",
                str(GUEST_PORT),
                "--recipient-file",
                str(recipient_file),
                "--inbox",
                str(inbox),
                "--state-dir",
                str(state),
                "--once",
            ],
            timeout=120,
        )
    except subprocess.TimeoutExpired:
        fail("writer timed out waiting for the guest")
    if proc.returncode != 0:
        fail(f"writer exited {proc.returncode}: {proc.stdout.strip()} {proc.stderr.strip()}")
    files = sorted(glob.glob(str(inbox / f"{SOURCE}-*.age")))
    if not files:
        fail("writer produced no encrypted batch")
    decrypted = run(["age", "-d", "-i", str(identity), files[0]])
    if decrypted.returncode != 0:
        fail(f"age -d failed: {decrypted.stderr.strip()}")
    batch = json.loads(decrypted.stdout)
    if batch.get("source") != SOURCE or batch.get("kind") != "batch":
        fail(f"decrypted batch has the wrong shape: {batch!r}")
    if not any(item.get("probe") == "kanbei-ingest-verify" for item in batch.get("items", [])):
        fail("decrypted batch does not contain the probe item")
    state_file = state / f"{SOURCE}.last-ok"
    if not state_file.exists():
        fail("writer did not record freshness state")
    say(f"PASS round-trip: {Path(files[0]).name} decrypts and carries the probe item")


def check_dns(env: dict) -> None:
    resolver = shutil.which("ingest-resolver")
    if resolver is None:
        fail("ingest-resolver is not on PATH")
    port = free_port()
    DNS_PORT[0] = port
    proc = subprocess.Popen(
        [resolver, "--policy", POLICY, "--bind", f"127.0.0.1:{port}", "--force-source", SOURCE],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        env=env,
    )
    try:
        time.sleep(0.5)
        refused = dns_query("example.com")
        if refused != 5:
            fail(f"non-allowlisted name got rcode {refused}, expected REFUSED")
        refused = dns_query("app.tuta.com")
        if refused != 5:
            fail(f"another source's name got rcode {refused}, expected REFUSED")
        say("PASS dns: example.com and app.tuta.com are REFUSED on the search source")
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()


def connect_lines(proc: subprocess.Popen, port: int, authority: str, hello: bytes | None) -> tuple[bytes, list[str]]:
    sock = socket.create_connection(("127.0.0.1", port), timeout=10)
    sock.sendall(f"CONNECT {authority} HTTP/1.1\r\nHost: {authority}\r\n\r\n".encode())
    response = b""
    try:
        sock.settimeout(5)
        if hello is not None:
            sock.sendall(hello)
        try:
            response = sock.recv(4096)
        except socket.timeout:
            response = b""
    finally:
        sock.close()
    time.sleep(0.3)
    proc.terminate()
    try:
        out, _ = proc.communicate(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        out = ""
    return response, out.splitlines()


def check_sni(env: dict) -> None:
    proxy = shutil.which("ingest-proxy")
    if proxy is None:
        fail("ingest-proxy is not on PATH")
    port = free_port()
    proc = subprocess.Popen(
        [
            proxy,
            "--policy",
            POLICY,
            "--bind",
            f"127.0.0.1:{port}",
            "--force-source",
            "tuta",
            "--verify-allow",
            "app.tuta.com",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        env=env,
    )
    time.sleep(0.7)
    response, lines = connect_lines(proc, port, "example.com:443", None)
    if b"403" not in response:
        fail(f"non-allowlisted CONNECT was not refused: {response!r}")
    if not any('"reason": "not_allowlisted"' in line for line in lines):
        fail("proxy did not log the non-allowlisted CONNECT")

    proc = subprocess.Popen(
        [
            proxy,
            "--policy",
            POLICY,
            "--bind",
            f"127.0.0.1:{port}",
            "--force-source",
            "tuta",
            "--verify-allow",
            "app.tuta.com",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        env=env,
    )
    time.sleep(0.7)
    hello = client_hello("example.com")
    response, lines = connect_lines(proc, port, "app.tuta.com:443", hello)
    if b"200" in response:
        fail("proxy accepted a ClientHello whose SNI does not match the CONNECT host")
    if not any('"reason": "sni_mismatch"' in line for line in lines):
        fail(f"proxy did not log the SNI mismatch: {lines[-4:]}")
    say("PASS sni: CONNECT example.com and a mismatched SNI are refused")


def check_egress(env: dict, since: str) -> None:
    out = journal(f"microvm@{GUEST}", since)
    if "INGEST-EGRESS-DROPPED" not in out:
        fail("the guest's direct-egress probe did not report a drop")
    if "INGEST-EGRESS-REACHED" in out:
        fail("the guest reached the internet directly")
    rules = run(["iptables", "-S", CHAIN])
    if rules.returncode != 0:
        fail(f"cannot read iptables chain {CHAIN}: {rules.stderr.strip()}")
    lines = [line for line in rules.stdout.splitlines() if line.startswith("-A ")]
    if not lines or not lines[-1].endswith("-j DROP"):
        fail(f"{CHAIN} has no final DROP: {lines}")
    for line in lines:
        if line == lines[-1]:
            continue
        if "-j ACCEPT" in line and "conntrack --ctstate ESTABLISHED,RELATED" not in line:
            fail(f"{CHAIN} grants egress: {line}")
    say(f"PASS egress: guest probe dropped and {CHAIN} only accepts conntrack")


def check_secret(since: str) -> None:
    out = journal(f"microvm@{GUEST}", since)
    if '"event": "secret"' not in out or '"mode": "0o400"' not in out:
        fail("the guest did not report a 0400 secret file on its read-only block device")
    say("PASS secret: guest sees the staged env at mode 0400")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="kanbei-ingest-verify")
    parser.parse_args(argv)
    require_root()
    require_hardware()
    env = os.environ.copy()
    env["PATH"] = os.pathsep.join([os.path.dirname(shutil.which("systemctl") or "/run/current-system/sw/bin"), env.get("PATH", "")])

    since = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime())
    run(["systemctl", "stop", f"ingest-writer-{SOURCE}.service"])
    try:
        run(["systemctl", "restart", f"microvm@{GUEST}.service"])
        if not wait_for(lambda: os.path.exists(VSOCK), 180):
            fail(f"{VSOCK} never appeared")
        if not wait_for(lambda: "INGEST-EGRESS-DROPPED" in journal(f"microvm@{GUEST}", since), 180):
            fail("the guest never reported its egress probe")
        check_secret(since)
        check_round_trip(Path(tempfile.mkdtemp(prefix="kanbei-ingest-verify-", dir="/run")))
        check_dns(env)
        check_sni(env)
        check_egress(env, since)
    finally:
        run(["systemctl", "start", f"ingest-writer-{SOURCE}.service"])
    say("PASS all ingest-plane proofs")
    return 0


if __name__ == "__main__":
    sys.exit(main())
