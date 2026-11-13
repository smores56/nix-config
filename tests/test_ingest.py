"""Unit tests for the ingest plane's pure policy and framing.

Covers the writer/guest framing boundary, batch schema and source validation,
age-recipient validation, hostname allowlisting, TLS SNI parsing and the DNS
question/answer helpers. No sockets are opened: the services are thin wrappers
around these functions.
"""

from __future__ import annotations

import importlib.util
import os
import socket
import ssl
import struct
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

POLICY = Path(__file__).parents[1] / "modules/lib/ingest/policy.py"
VALID_RECIPIENT = "age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p"


def load_policy():
    spec = importlib.util.spec_from_file_location("ingest_policy", POLICY)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def load_tool(name: str):
    """Load a module that imports its siblings (`policy`) from beside itself."""
    tools = POLICY.parent
    if str(tools) not in sys.path:
        sys.path.insert(0, str(tools))
    spec = importlib.util.spec_from_file_location(f"ingest_{name}", tools / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


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


class FramingTests(unittest.TestCase):
    def setUp(self):
        self.p = load_policy()

    def test_round_trip_multiple_frames(self):
        decoder = self.p.FrameDecoder()
        stream = self.p.encode_frame(b'{"a":1}') + self.p.encode_frame(b'{"b":2}')
        self.assertEqual(decoder.feed(stream), [b'{"a":1}', b'{"b":2}'])
        self.assertEqual(decoder.pending, 0)

    def test_partial_frame_waits(self):
        decoder = self.p.FrameDecoder()
        frame = self.p.encode_frame(b"hello")
        self.assertEqual(decoder.feed(frame[:3]), [])
        self.assertEqual(decoder.feed(frame[3:]), [b"hello"])

    def test_zero_and_oversize_lengths_are_refused(self):
        decoder = self.p.FrameDecoder(max_bytes=8)
        with self.assertRaises(self.p.PolicyError):
            decoder.feed(struct.pack(">I", 0))
        with self.assertRaises(self.p.PolicyError):
            decoder.feed(struct.pack(">I", 9) + b"x" * 9)

    def test_encode_refuses_empty_and_oversize(self):
        with self.assertRaises(self.p.PolicyError):
            self.p.encode_frame(b"")
        with self.assertRaises(self.p.PolicyError):
            self.p.encode_frame(b"x" * (self.p.MAX_BATCH_BYTES + 1))


class BatchValidationTests(unittest.TestCase):
    def setUp(self):
        self.p = load_policy()
        self.batch = b'{"v":1,"source":"tuta","kind":"batch","seq":3,"items":[]}'

    def test_accepts_a_valid_batch(self):
        batch = self.p.validate_batch(self.batch, "tuta")
        self.assertEqual(batch["seq"], 3)

    def test_refuses_a_foreign_source(self):
        with self.assertRaisesRegex(self.p.PolicyError, "is not 'finance'"):
            self.p.validate_batch(self.batch, "finance")

    def test_refuses_wrong_version_kind_and_keys(self):
        for payload in (
            b'{"v":2,"source":"tuta","kind":"batch","items":[]}',
            b'{"v":1,"source":"tuta","kind":"heartbeat","items":[]}',
            b'{"v":1,"source":"tuta","kind":"batch","items":[],"extra":true}',
            b'{"v":1,"source":"tuta","kind":"batch"}',
            b'{"v":1,"source":"tuta","kind":"batch","items":{}}',
            b'{"v":1,"source":"tuta","kind":"batch","items":[],"seq":-1}',
            b"not json",
        ):
            with self.subTest(payload=payload), self.assertRaises(self.p.PolicyError):
                self.p.validate_batch(payload, "tuta")

    def test_heartbeat_schema(self):
        envelope = {"v": 1, "kind": "heartbeat", "sources": {"tuta": {"stale": False, "window_s": 1800}}}
        self.assertEqual(self.p.validate_heartbeat(envelope), envelope)
        with self.assertRaises(self.p.PolicyError):
            self.p.validate_heartbeat({"v": 1, "kind": "heartbeat", "sources": {"tuta": {}}})


class AgeRecipientTests(unittest.TestCase):
    def setUp(self):
        self.p = load_policy()

    def test_accepts_one_recipient_line(self):
        self.assertEqual(self.p.validate_age_recipient(VALID_RECIPIENT + "\n"), VALID_RECIPIENT)

    def test_refuses_keys_junk_and_multiple_lines(self):
        for text in (
            "",
            "AGE-SECRET-KEY-1QQL3Z7HJY54PW3HYWW5AYYFG7ZQGVC7W3J2ELW8ZMRJ2KG5SFN9AQMCAC8P",
            VALID_RECIPIENT + "\n" + VALID_RECIPIENT,
            VALID_RECIPIENT.replace("age1", "age2"),
            "age1" + "q" * 57,
        ):
            with self.subTest(text=text), self.assertRaises(self.p.PolicyError):
                self.p.validate_age_recipient(text)


class AllowlistTests(unittest.TestCase):
    def setUp(self):
        self.p = load_policy()
        self.allow = ["app.tuta.com", "sync-v2.brave.com"]

    def test_exact_match_is_case_and_dot_insensitive(self):
        self.assertTrue(self.p.host_allowed("APP.Tuta.com.", self.allow))

    def test_refuses_suffixes_ips_and_non_hostnames(self):
        for host in (
            "app.tuta.com.evil.example",
            "tuta.com",
            "1.2.3.4",
            "::1",
            "app.tuta.com:443",
            "https://app.tuta.com",
            "user@app.tuta.com",
            "",
            None,
        ):
            with self.subTest(host=host):
                self.assertFalse(self.p.host_allowed(host, self.allow))

    def test_parse_authority_refuses_ip_literals_and_bad_ports(self):
        self.assertEqual(self.p.parse_authority("app.tuta.com:443"), ("app.tuta.com", 443))
        for authority in ("1.2.3.4:443", "[::1]:443", "app.tuta.com:https", "app.tuta.com:70000"):
            with self.subTest(authority=authority), self.assertRaises(self.p.PolicyError):
                self.p.parse_authority(authority)

    def test_absolute_form(self):
        self.assertEqual(
            self.p.parse_absolute_form("http://app.tuta.com/inbox?q=1"),
            ("app.tuta.com", 80, "/inbox?q=1"),
        )
        with self.assertRaises(self.p.PolicyError):
            self.p.parse_absolute_form("https://app.tuta.com/")
        with self.assertRaises(self.p.PolicyError):
            self.p.parse_absolute_form("http://1.2.3.4/")
        # Non-web ports are refused, like CONNECT's HTTPS-only rule.
        for target in ("http://app.tuta.com:8080/x", "http://app.tuta.com:443/x"):
            with self.subTest(target=target):
                self.assertEqual(
                    self.p.parse_absolute_form("http://app.tuta.com:443/x"),
                    ("app.tuta.com", 443, "/x"),
                )
                with self.assertRaises(self.p.PolicyError):
                    self.p.parse_absolute_form("http://app.tuta.com:8080/x")


class SniTests(unittest.TestCase):
    def setUp(self):
        self.p = load_policy()

    def test_parses_a_real_client_hello(self):
        self.assertEqual(self.p.parse_client_hello_sni(client_hello("app.tuta.com")), "app.tuta.com")

    def test_needs_more_data_until_the_record_is_complete(self):
        hello = client_hello("app.tuta.com")
        with self.assertRaises(self.p.NeedMoreData):
            self.p.parse_client_hello_sni(hello[:5])
        with self.assertRaises(self.p.NeedMoreData):
            self.p.parse_client_hello_sni(hello[:-1])

    def test_refuses_non_handshake(self):
        with self.assertRaises(self.p.PolicyError):
            self.p.parse_client_hello_sni(b"GET / HTTP/1.1\r\n\r\n")


class DnsTests(unittest.TestCase):
    def setUp(self):
        self.p = load_policy()

    @staticmethod
    def query(name: str, qtype: int = 1) -> bytes:
        qname = b"".join(bytes([len(label)]) + label.encode() for label in name.split(".")) + b"\x00"
        return struct.pack(">HHHHHH", 7, 0x0100, 1, 0, 0, 0) + qname + struct.pack(">HH", qtype, 1)

    def test_question_round_trip(self):
        ident, qname, qtype, qclass, question = self.p.parse_dns_question(self.query("app.tuta.com"))
        self.assertEqual((ident, qname, qtype, qclass), (7, "app.tuta.com", 1, 1))
        response = self.p.build_dns_response(ident, question, qtype, ["203.0.113.10"])
        self.assertEqual(response[:2], b"\x00\x07")
        self.assertEqual(struct.unpack(">H", response[6:8])[0], 1)

    def test_refuses_bad_questions(self):
        with self.assertRaises(self.p.PolicyError):
            self.p.parse_dns_question(b"\x00" * 11)
        with self.assertRaises(self.p.PolicyError):
            self.p.parse_dns_question(self.query("app.tuta.com")[:14] + b"\xc0\x0c" + b"\x00\x01\x00\x01")

    def test_refused_response_has_no_answers(self):
        ident, _qname, qtype, _qclass, question = self.p.parse_dns_question(self.query("example.com"))
        response = self.p.build_dns_response(ident, question, qtype, [], rcode=5)
        self.assertEqual(struct.unpack(">H", response[6:8])[0], 0)
        self.assertEqual(struct.unpack(">H", response[2:4])[0] & 0xF, 5)


class ProxyConnectTests(unittest.TestCase):
    """CONNECT ordering: the reply must precede the ClientHello.

    A client starts TLS only once it has the `200 Connection established`, so a proxy
    that reads the ClientHello first deadlocks and then answers 403 — which the guest
    reports as a failed tunnel rather than a refusal.
    """

    def setUp(self):
        self.p = load_tool("proxy")
        data = {
            "sources": {
                "immich": {
                    "gateway": "10.77.13.1",
                    "client": "10.77.13.2",
                    "allow": ["photos.sammohr.dev"],
                }
            }
        }
        self.proxy = self.p.Proxy(data, "immich", [], 3128)

    def test_replies_before_waiting_for_the_client_hello(self):
        client, server = socket.socketpair()
        upstream, upstream_peer = socket.socketpair()
        self.proxy._dial = lambda host, port: upstream
        handler = threading.Thread(
            target=self.proxy.handle,
            args=(server, ("10.77.13.2", 40000), ("10.77.13.1", 3128)),
            daemon=True,
        )
        handler.start()
        try:
            client.settimeout(3)
            client.sendall(b"CONNECT photos.sammohr.dev:443 HTTP/1.1\r\nHost: photos.sammohr.dev:443\r\n\r\n")
            # No ClientHello yet: the 200 must arrive anyway.
            self.assertIn(b"200", client.recv(64))
            client.sendall(client_hello("photos.sammohr.dev"))
            # The handshake record reaches the upstream only after the SNI check.
            self.assertEqual(upstream_peer.recv(5)[:1], b"\x16")
        finally:
            client.close()
            server.close()
            upstream.close()
            upstream_peer.close()
            handler.join(timeout=3)


class ProxyRelayTests(unittest.TestCase):
    """The relay must survive backpressure.

    A 1 MiB album response overflows the guest's socket buffers, so a relay that calls
    sendall once on a non-blocking socket gets BlockingIOError, treats it as a dead
    peer and tears the tunnel down mid-body — which the collector sees as
    `IncompleteRead` after exactly one buffer's worth of bytes.
    """

    def test_backpressure_does_not_truncate_the_stream(self):
        p = load_tool("proxy")
        client, server = socket.socketpair()
        upstream, upstream_peer = socket.socketpair()
        try:
            for sock in (server, upstream):
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4096)
            client.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
            payload = os.urandom(1 << 20)

            def feed():
                upstream_peer.sendall(payload)
                upstream_peer.shutdown(socket.SHUT_WR)

            relay = threading.Thread(
                target=p.Proxy._splice,
                args=(server, upstream, "immich", "photos.sammohr.dev", 443, time.monotonic()),
                daemon=True,
            )
            relay.start()
            threading.Thread(target=feed, daemon=True).start()
            received = bytearray()
            client.settimeout(5)
            while len(received) < len(payload):
                chunk = client.recv(65536)
                if not chunk:
                    break
                received += chunk
            self.assertEqual(len(received), len(payload))
            self.assertEqual(bytes(received), payload)
            # Closing the far ends EOFs the relay; join before interpreter shutdown,
            # or the daemon thread dies mid-select and crashes finalization.
            client.close()
            upstream_peer.close()
            relay.join(timeout=5)
            self.assertFalse(relay.is_alive())
        finally:
            for sock in (client, server, upstream, upstream_peer):
                sock.close()


class WriterHandshakeTests(unittest.TestCase):
    """The `OK <port>` reply and the first frame can share one read.

    A guest with a queued batch answers CONNECT and immediately writes the first
    frame; one recv() coalesces them. Judging the coalesced buffer as the reply
    rejected a valid handshake, which is what `kanbei-ingest-verify` hit.
    """

    def test_the_handshake_keeps_the_first_frame(self):
        writer = load_tool("writer")
        policy = load_policy()
        frame = policy.encode_frame(b'{"v":1,"source":"search","kind":"batch","seq":1,"items":[]}')
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "notify.vsock")
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(path)
            server.listen(1)
            try:
                def answer():
                    conn, _ = server.accept()
                    with conn:
                        conn.recv(64)
                        conn.sendall(b"OK 1073741827\n" + frame)

                threading.Thread(target=answer, daemon=True).start()
                sock = writer.connect_vsock(path, 7014, timeout=5)
                try:
                    self.assertEqual(sock.recv(len(frame)), frame)
                finally:
                    sock.close()
            finally:
                server.close()


if __name__ == "__main__":
    unittest.main()
