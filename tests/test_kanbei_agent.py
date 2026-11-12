"""Unit tests for the kanbei guest agent helpers.

Covers the UDS->vsock forwarder's byte splicing and the age-recipient wire: one token
line, one recipient line, and an `OK` reply. The recipient shape is also checked against
the host's validator so the two ends cannot drift.
"""

from __future__ import annotations

import importlib.util
import os
import socket
import sys
import tempfile
import threading
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
KANBEI = REPO / "modules/lib/kanbei"

sys.path.insert(0, str(KANBEI))

VALID_RECIPIENT = "age1" + "q" * 58
TOKEN = b"t" * 32


def load(name: str):
    spec = importlib.util.spec_from_file_location(name, KANBEI / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def recv_line(sock: socket.socket) -> bytes:
    data = bytearray()
    while True:
        chunk = sock.recv(1)
        if not chunk or chunk == b"\n":
            return bytes(data)
        data += chunk


class ForwarderTests(unittest.TestCase):
    def setUp(self):
        self.forward = load("uds_forward")

    def test_pipe_splices_both_directions(self):
        left, left_peer = socket.socketpair()
        right, right_peer = socket.socketpair()
        thread = threading.Thread(target=self.forward.pipe, args=(left, right), daemon=True)
        thread.start()
        try:
            left_peer.sendall(b"request")
            self.assertEqual(right_peer.recv(7), b"request")
            right_peer.sendall(b"reply")
            self.assertEqual(left_peer.recv(5), b"reply")
        finally:
            left_peer.close()
            right_peer.close()
            thread.join(2)
            left.close()
            right.close()

    def test_handle_connects_and_relays(self):
        client, guest = socket.socketpair()
        upstream_peer, upstream = socket.socketpair()
        thread = threading.Thread(
            target=self.forward.handle,
            args=(guest, lambda: upstream),
            daemon=True,
        )
        thread.start()
        self.addCleanup(thread.join, 2)
        try:
            client.sendall(b"hello")
            self.assertEqual(upstream_peer.recv(5), b"hello")
            upstream_peer.sendall(b"world")
            self.assertEqual(client.recv(5), b"world")
        finally:
            client.close()
            upstream_peer.close()

    def test_handle_closes_on_connect_failure(self):
        client, guest = socket.socketpair()
        self.addCleanup(client.close)

        def refuse():
            raise OSError("host is down")

        self.forward.handle(guest, refuse)
        self.assertEqual(client.recv(1), b"")

    def test_listen_uds_replaces_a_stale_path(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "csr.sock")
            Path(path).touch()
            listener = self.forward.listen_uds(path)
            self.addCleanup(listener.close)
            import stat

            self.assertTrue(stat.S_ISSOCK(os.stat(path).st_mode))
            self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)


class AgePublishTests(unittest.TestCase):
    def setUp(self):
        self.publish_mod = load("age_publish")

    def write(self, text: str) -> str:
        handle = tempfile.NamedTemporaryFile("w", delete=False, suffix=".txt")
        handle.write(text)
        handle.close()
        self.addCleanup(os.unlink, handle.name)
        return handle.name

    def test_read_recipient_accepts_exactly_one_recipient(self):
        path = self.write(VALID_RECIPIENT + "\n")
        self.assertEqual(self.publish_mod.read_recipient(path), VALID_RECIPIENT)

    def test_read_recipient_rejects_an_identity_key(self):
        path = self.write("AGE-SECRET-KEY-1" + "Q" * 58 + "\n")
        with self.assertRaises(self.publish_mod.PublishError):
            self.publish_mod.read_recipient(path)

    def test_read_recipient_rejects_extra_lines(self):
        path = self.write(VALID_RECIPIENT + "\n" + VALID_RECIPIENT + "\n")
        with self.assertRaises(self.publish_mod.PublishError):
            self.publish_mod.read_recipient(path)

    def test_recipient_shape_matches_the_host_validator(self):
        spec = importlib.util.spec_from_file_location("ingest_policy", REPO / "modules/lib/ingest/policy.py")
        policy = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(policy)
        self.assertEqual(policy.validate_age_recipient(VALID_RECIPIENT), VALID_RECIPIENT)
        with self.assertRaises(policy.PolicyError):
            policy.validate_age_recipient("age1" + "q" * 10)

    def publish_over_socketpair(self, reply: bytes, on_wire):
        server, client = socket.socketpair()
        self.addCleanup(server.close)
        outcome: dict[str, object] = {}

        def run():
            try:
                self.publish_mod.publish(VALID_RECIPIENT, TOKEN, lambda: client)
                outcome["ok"] = True
            except Exception as exc:  # noqa: BLE001 - the test asserts its type
                outcome["error"] = exc

        thread = threading.Thread(target=run, daemon=True)
        thread.start()
        try:
            on_wire(server)
            server.sendall(reply)
        finally:
            thread.join(2)
        return outcome

    def test_publish_writes_token_then_recipient_and_requires_ok(self):
        seen: list[bytes] = []

        def on_wire(server):
            seen.append(recv_line(server))
            seen.append(recv_line(server))

        outcome = self.publish_over_socketpair(b"OK\n", on_wire)
        self.assertEqual(
            seen,
            [b"KANBEI-AUTH 1 " + TOKEN, VALID_RECIPIENT.encode("ascii")],
        )
        self.assertTrue(outcome.get("ok"))

    def test_publish_reports_a_host_refusal(self):
        outcome = self.publish_over_socketpair(
            b"ERR\n",
            lambda server: (recv_line(server), recv_line(server)),
        )
        self.assertIsInstance(outcome.get("error"), self.publish_mod.PublishError)


if __name__ == "__main__":
    unittest.main()
