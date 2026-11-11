"""Unit tests for the Kanbei TCP-to-vsock relay.

The relay's AF_VSOCK client is injected, so these tests splice a real TCP socket to the other
end of a UNIX socket pair and prove both directions carry bytes unchanged. The actual
AF_VSOCK connect is a single kernel call and is exercised only on the host with a running
guest.
"""

from __future__ import annotations

import importlib.util
import socket
import threading
import unittest
from pathlib import Path


def load_module():
    path = Path(__file__).parents[1] / "modules/lib/kanbei/relay.py"
    spec = importlib.util.spec_from_file_location("kanbei_relay", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class PipeTests(unittest.TestCase):
    def setUp(self):
        self.relay = load_module()

    def test_pipe_carries_bytes_both_ways(self):
        left, left_peer = socket.socketpair()
        right, right_peer = socket.socketpair()
        for sock in (left, left_peer, right, right_peer):
            self.addCleanup(sock.close)
        worker = threading.Thread(
            target=self.relay.pipe, args=(left, right), daemon=True
        )
        worker.start()
        left_peer.sendall(b"hello guest")
        self.assertEqual(right_peer.recv(64), b"hello guest")
        right_peer.sendall(b"hello tunnel")
        self.assertEqual(left_peer.recv(64), b"hello tunnel")
        left_peer.shutdown(socket.SHUT_WR)
        right_peer.shutdown(socket.SHUT_WR)
        worker.join(timeout=5)
        self.assertFalse(worker.is_alive())

    def test_half_close_still_delivers_the_other_direction(self):
        left, left_peer = socket.socketpair()
        right, right_peer = socket.socketpair()
        for sock in (left, left_peer, right, right_peer):
            self.addCleanup(sock.close)
        worker = threading.Thread(
            target=self.relay.pipe, args=(left, right), daemon=True
        )
        worker.start()
        left_peer.sendall(b"last request")
        left_peer.shutdown(socket.SHUT_WR)
        self.assertEqual(right_peer.recv(64), b"last request")
        self.assertEqual(right_peer.recv(64), b"")
        right_peer.sendall(b"final answer")
        self.assertEqual(left_peer.recv(64), b"final answer")
        right_peer.shutdown(socket.SHUT_WR)
        worker.join(timeout=5)


class ServeTests(unittest.TestCase):
    def setUp(self):
        self.relay = load_module()
        self.listener = socket.create_server(("127.0.0.1", 0))
        self.addCleanup(self.listener.close)
        self.stop = threading.Event()

    def test_tcp_client_is_spliced_to_the_injected_vsock_endpoint(self):
        guest, guest_peer = socket.socketpair()
        self.addCleanup(guest.close)
        self.addCleanup(guest_peer.close)
        worker = threading.Thread(
            target=self.relay.serve,
            args=(self.listener, lambda: guest, self.stop),
            daemon=True,
        )
        worker.start()
        client = socket.create_connection(self.listener.getsockname(), timeout=5)
        self.addCleanup(client.close)
        client.sendall(b"GET / HTTP/1.1\r\n\r\n")
        self.assertEqual(guest_peer.recv(128), b"GET / HTTP/1.1\r\n\r\n")
        guest_peer.sendall(b"HTTP/1.1 200 OK\r\n\r\n")
        self.assertEqual(client.recv(128), b"HTTP/1.1 200 OK\r\n\r\n")
        client.close()
        self.assertEqual(guest_peer.recv(16), b"")
        self.stop.set()
        worker.join(timeout=5)
        self.assertFalse(worker.is_alive())

    def test_failed_vsock_connect_closes_the_tcp_side(self):
        def refuse():
            raise ConnectionRefusedError("no guest")

        worker = threading.Thread(
            target=self.relay.serve, args=(self.listener, refuse, self.stop), daemon=True
        )
        worker.start()
        client = socket.create_connection(self.listener.getsockname(), timeout=5)
        self.addCleanup(client.close)
        self.assertEqual(client.recv(16), b"")
        self.stop.set()
        worker.join(timeout=5)

    def test_systemd_listener_is_none_without_socket_activation(self):
        self.assertIsNone(self.relay.systemd_listener())


if __name__ == "__main__":
    unittest.main()
