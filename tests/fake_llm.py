"""A small in-process llama.cpp server double for the model-client tests."""

from __future__ import annotations

import json
import os
import socketserver
import threading
from http.server import BaseHTTPRequestHandler
from typing import Any
from urllib.parse import urlparse


class FakeLLM:
    def __init__(
        self,
        unix_path: str,
        *,
        models: tuple[str, ...] = ("photo-triage",),
        answer: str = "red",
        text_answer: str = "unknown",
        ignore_images: bool = False,
        finish_reason: str = "stop",
        content: str | None = None,
        fail_status: int | None = None,
    ) -> None:
        self.unix_path = unix_path
        self.models = list(models)
        self.answer = answer
        self.text_answer = text_answer
        self.ignore_images = ignore_images
        self.finish_reason = finish_reason
        self.content = content
        self.fail_status = fail_status
        self.failures: list[int] = []
        self.requests: list[tuple[str, str, dict[str, Any]]] = []
        self._server: socketserver.ThreadingUnixStreamServer | None = None
        self._thread: threading.Thread | None = None

    def __enter__(self) -> "FakeLLM":
        self.start()
        return self

    def __exit__(self, *exc: object) -> None:
        self.stop()

    def start(self) -> None:
        owner = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.0"

            def do_GET(self) -> None:
                owner._handle(self)

            def do_POST(self) -> None:
                owner._handle(self)

            def log_message(self, *args: object) -> None:
                return

        class Server(socketserver.ThreadingUnixStreamServer):
            daemon_threads = True

        self._server = Server(self.unix_path, Handler)
        os.chmod(self.unix_path, 0o600)
        self._thread = threading.Thread(
            target=self._server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True
        )
        self._thread.start()

    def stop(self) -> None:
        if self._server is not None:
            self._server.shutdown()
            self._server.server_close()
        if self._thread is not None:
            self._thread.join(timeout=5)
        try:
            os.unlink(self.unix_path)
        except FileNotFoundError:
            pass
        self._server = None
        self._thread = None

    def queue_failure(self, status: int, count: int = 1) -> None:
        self.failures.extend([status] * count)

    def _handle(self, request: BaseHTTPRequestHandler) -> None:
        parsed = urlparse(request.path)
        length = int(request.headers.get("Content-Length", "0") or 0)
        body = request.rfile.read(length) if length else b""
        payload = json.loads(body) if body else {}
        self.requests.append((request.command, parsed.path, payload))
        failure = self.failures.pop(0) if self.failures else self.fail_status
        if failure is not None:
            self._send_json(request, failure, {"message": "injected failure"})
            return
        if request.command == "GET" and parsed.path == "/v1/models":
            self._send_json(
                request, 200, {"data": [{"id": model} for model in self.models]}
            )
            return
        if request.command == "POST" and parsed.path == "/v1/chat/completions":
            messages = payload.get("messages") or []
            has_image = any(
                isinstance(part, dict) and part.get("type") == "image_url"
                for message in messages
                if isinstance(message, dict)
                for part in (message.get("content") or [])
                if isinstance(part, dict)
            )
            texts = [
                str(part.get("text", ""))
                for message in messages
                if isinstance(message, dict)
                for part in (message.get("content") or [])
                if isinstance(part, dict) and part.get("type") == "text"
            ]
            is_color_question = any("dominant background color" in text for text in texts)
            content = (
                self.answer
                if is_color_question
                else self.content
                if self.content is not None
                else self.answer
                if has_image
                else self.text_answer
            )
            prompt_tokens = 100 if has_image and not self.ignore_images else 10
            self._send_json(
                request,
                200,
                {
                    "choices": [
                        {
                            "message": {"content": content},
                            "finish_reason": self.finish_reason,
                        }
                    ],
                    "usage": {"prompt_tokens": prompt_tokens, "completion_tokens": 1},
                },
            )
            return
        self._send_json(request, 404, {"message": "Not found"})

    @staticmethod
    def _send_json(request: BaseHTTPRequestHandler, status: int, payload: dict[str, Any]) -> None:
        data = json.dumps(payload).encode("utf-8")
        request.send_response(status)
        request.send_header("Content-Type", "application/json")
        request.send_header("Content-Length", str(len(data)))
        request.end_headers()
        request.wfile.write(data)
