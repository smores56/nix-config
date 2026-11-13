"""Root-only, hardware-gated proof for the ingest plane.

Run as root on smortress (or through /run/wrappers/bin/sudo):

    /run/wrappers/bin/sudo /run/current-system/sw/bin/kanbei-ingest-verify

It stops the production search writer, reboots the `search` guest so its test
batch is seeded again, and then proves:

  a. one batch round-trips through ingest-writer and decrypts with the test age
     identity (the same framing/encryption path as Kanbei's published key);
  b. a non-allowlisted DNS name and a non-matching SNI are refused; and
  c. the guest cannot egress directly: its own probe logs INGEST-EGRESS-DROPPED
     and the per-tap forward chain ends in DROP with no non-conntrack ACCEPT; and
  d. the cluster-digest share and its parent chain are unreadable and unwritable
     by the human account, so `smores` cannot rename or replace the tree.

It restores the writer and leaves the guest running. Nothing here runs in CI;
the eval checks cover the policy validators instead.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
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
# The digest tree lives in the root-only ingest state root, never under
# `/var/lib/data` (0751 `smores:users`), where the human could rename the child.
DIGEST = "/var/lib/kanbei-ingest/shares/cluster-digest"
# Every directory between the tree and the state root must deny the human both read
# and write; without traversal or write, a rename/replace is impossible.
DIGEST_PRIVATE_PARENTS = ("/var/lib/kanbei-ingest", "/var/lib/kanbei-ingest/shares")
# Above the state root only write matters: the human may read `/var/lib`, but cannot
# rename anything in it.
DIGEST_SHARED_PARENTS = ("/var/lib", "/var")
DIGEST_USER = "kanbei-digest"
HUMAN = "smores"


def say(message: str) -> None:
    print(f"kanbei-ingest-verify: {message}", flush=True)


def fail(message: str) -> None:
    print(f"kanbei-ingest-verify: FAIL: {message}", file=sys.stderr, flush=True)
    raise SystemExit(1)


def run(cmd: list[str], **kwargs: object) -> subprocess.CompletedProcess:
    """Run a helper, reporting a missing binary as a FAIL instead of a traceback."""
    try:
        return subprocess.run(cmd, check=False, capture_output=True, text=True, **kwargs)
    except FileNotFoundError:
        fail(f"{cmd[0]} is not on PATH")
        raise AssertionError("unreachable")


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
    # The CONNECT reply precedes the ClientHello by design, so a refusal is that reply
    # followed by a close: nothing from an upstream ever arrives, and the proxy logs the
    # mismatch. A ServerHello record (0x16 0x03) would mean it dialled.
    if not response.startswith(b"HTTP/1.1 200"):
        fail(f"expected the CONNECT reply before the SNI check: {response!r}")
    if b"\x16\x03" in response:
        fail("proxy accepted a ClientHello whose SNI does not match the CONNECT host")
    if any('"event": "allow"' in line for line in lines):
        fail("proxy dialled upstream for a mismatched SNI")
    if not any('"reason": "sni_mismatch"' in line for line in lines):
        fail(f"proxy did not log the SNI mismatch: {lines[-4:]}")
    say("PASS sni: CONNECT example.com and a mismatched SNI are refused")


CONNTRACK_STATES = {"ESTABLISHED", "RELATED"}


def granted_states(rule: str) -> set[str] | None:
    """The ctstate set of a conntrack rule, or None when the rule is not one.

    iptables normalises the set alphabetically (`RELATED,ESTABLISHED`), so compare
    sets instead of one spelling of the states.
    """
    match = re.search(r"--ctstate\s+([A-Z,]+)", rule)
    return set(match.group(1).split(",")) if match else None


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
        if "-j ACCEPT" in line and granted_states(line) != CONNTRACK_STATES:
            fail(f"{CHAIN} grants egress: {line}")
    say(f"PASS egress: guest probe dropped and {CHAIN} only accepts conntrack")


def check_secret(since: str) -> None:
    out = journal(f"microvm@{GUEST}", since)
    if '"event": "secret"' not in out or '"mode": "0o400"' not in out:
        fail("the guest did not report a 0400 secret file on its read-only block device")
    say("PASS secret: guest sees the staged env at mode 0400")


def permission_problem(
    role: str, path: str, mode: int, owner_uid: int, want_uid: str, human_uid: str
) -> str | None:
    """Why `path` breaks its role's permission rule, or None when it holds.

    A digest share is 0770 on its own uid: the group-write bit is the design, bounded
    by the exact mode and the owner. Only the parents must be closed to group and
    other writes — applying the parent rule to the share rejected a correct tree.
    """
    if human_uid and str(owner_uid) == human_uid:
        return f"{path} is owned by {HUMAN}; must be root- or {DIGEST_USER}-owned"
    if role == "share":
        if mode != 0o770:
            return f"{path} is {mode:o}, expected 0770"
        if want_uid and str(owner_uid) != want_uid:
            return f"{path} is owned by uid {owner_uid}, expected {DIGEST_USER} ({want_uid})"
        return None
    if mode & 0o022:
        return f"{path} is group/other writable ({mode:o}); the digest parent chain must be private"
    return None


def check_digest_share() -> None:
    """The digest tree is 0770 on its own uid inside a root-only parent chain."""
    try:
        info = os.stat(DIGEST)
    except FileNotFoundError:
        fail(f"{DIGEST} is missing; the cluster guest is not installed")
    want = run(["id", "-u", DIGEST_USER]).stdout.strip()
    human = run(["id", "-u", HUMAN]).stdout.strip()
    if not human:
        fail(f"{HUMAN} does not exist; cannot prove the digest share is private")
    problem = permission_problem("share", DIGEST, info.st_mode & 0o777, info.st_uid, want, human)
    if problem:
        fail(problem)
    shell = shutil.which("bash") or "/run/current-system/sw/bin/bash"

    def human_denied(path: str, flags: tuple[tuple[str, str], ...]) -> None:
        for flag, word in flags:
            result = run(["runuser", "-u", HUMAN, "--", shell, "-c", f"test {flag} {path}"])
            if result.returncode == 0:
                fail(f"{HUMAN} can {word} {path}; the digest share must be private")

    def denies(path: str, flags: tuple[tuple[str, str], ...]) -> None:
        probe = os.stat(path)
        problem = permission_problem("parent", path, probe.st_mode & 0o777, probe.st_uid, "", human)
        if problem:
            fail(problem)
        human_denied(path, flags)

    # Read and write on the tree and its private chain; write alone above it. The
    # share's own mode and owner are the share rule, not the parent rule.
    human_denied(DIGEST, (("-r", "read"), ("-w", "write")))
    for parent in DIGEST_PRIVATE_PARENTS:
        denies(parent, (("-r", "read"), ("-w", "write")))
    for parent in DIGEST_SHARED_PARENTS:
        denies(parent, (("-w", "write"),))
    say(
        f"PASS digest: {DIGEST} is 0770 {DIGEST_USER} inside a root-only chain; "
        f"{HUMAN} can neither read nor write it nor its parents"
    )


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
        check_digest_share()
    finally:
        run(["systemctl", "start", f"ingest-writer-{SOURCE}.service"])
    say("PASS all ingest-plane proofs")
    return 0


if __name__ == "__main__":
    sys.exit(main())
