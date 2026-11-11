"""Scoring-model client over the scoring server's Unix socket."""

from __future__ import annotations

import base64
import http.client
import io
import json
import re
import time
from typing import Any

from PIL import Image, ImageDraw

from .transport import UnixHTTPConnection

MODEL_ALIAS = "photo-triage"
TRANSIENT_STATUS = frozenset({408, 429, 500, 502, 503, 504})


def _token_count(value: object) -> int | str:
    """Server-supplied usage field; never let it abort a run."""
    try:
        return int(value)  # type: ignore[arg-type]
    except (TypeError, ValueError, OverflowError):
        return "unknown"


class LLMError(Exception):
    def __init__(
        self,
        message: str,
        *,
        status: int = 0,
        transient: bool = False,
        truncated_content: str | None = None,
    ) -> None:
        super().__init__(message)
        self.status = status
        self.transient = transient
        # A reply cut at max_tokens; the caller may still salvage its prefix.
        self.truncated_content = truncated_content


def _synthetic_image() -> str:
    image = Image.new("RGB", (256, 256), (200, 20, 20))
    ImageDraw.Draw(image).rectangle([64, 64, 192, 192], fill=(250, 250, 250))
    buffer = io.BytesIO()
    image.save(buffer, "PNG")
    encoded = base64.b64encode(buffer.getvalue()).decode()
    return f"data:image/png;base64,{encoded}"


class LLMClient:
    def __init__(
        self, *, socket_path: str, model: str = MODEL_ALIAS, timeout: float = 300
    ) -> None:
        self.socket_path = socket_path
        self.model = model
        self.timeout = timeout

    def _request(self, method: str, path: str, body: bytes | None = None) -> dict[str, Any]:
        connection = UnixHTTPConnection(self.socket_path, timeout=self.timeout)
        headers = {"Accept": "application/json"}
        if body is not None:
            headers["Content-Type"] = "application/json"
        try:
            connection.request(method, path, body=body, headers=headers)
            response = connection.getresponse()
            data = response.read()
            status = response.status
        except (OSError, http.client.HTTPException) as error:
            raise LLMError(f"scoring model request failed: {error}", transient=True) from error
        finally:
            connection.close()
        if status >= 400:
            raise LLMError(
                f"scoring model returned {status}: {data.decode('utf-8', 'replace')[:200]}",
                status=status,
                transient=status in TRANSIENT_STATUS,
            )
        try:
            payload = json.loads(data)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise LLMError("scoring model response is not JSON") from error
        if not isinstance(payload, dict):
            raise LLMError("scoring model response is not an object")
        return payload

    def wait_ready(self, timeout: float = 600, interval: float = 1.0) -> None:
        deadline = time.monotonic() + timeout
        last: LLMError | None = None
        while time.monotonic() < deadline:
            try:
                self.models()
                return
            except LLMError as error:
                if not error.transient:
                    raise
                last = error
                time.sleep(interval)
        raise LLMError(
            f"scoring model not ready after {timeout:.0f}s: {last}",
            transient=True,
        )

    def models(self) -> list[str]:
        payload = self._request("GET", "/v1/models")
        data = payload.get("data")
        if not isinstance(data, list):
            raise LLMError("scoring model /v1/models has no data list")
        return [str(item.get("id")) for item in data if isinstance(item, dict)]

    def chat(
        self,
        messages: list[dict[str, Any]],
        *,
        max_tokens: int = 512,
        response_format: dict[str, Any] | None = None,
        temperature: float = 0,
    ) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "model": self.model,
            "messages": messages,
            "temperature": temperature,
            "max_tokens": max_tokens,
            "chat_template_kwargs": {"enable_thinking": False},
        }
        if response_format is not None:
            payload["response_format"] = response_format
        response = self._request(
            "POST", "/v1/chat/completions", json.dumps(payload).encode("utf-8")
        )
        choices = response.get("choices")
        if not isinstance(choices, list) or not choices:
            raise LLMError("scoring model returned no choices")
        choice = choices[0]
        if not isinstance(choice, dict):
            raise LLMError("scoring model choice is not an object")
        message = choice.get("message")
        content = message.get("content") if isinstance(message, dict) else None
        if choice.get("finish_reason") == "length":
            usage = response.get("usage")
            completion = usage.get("completion_tokens") if isinstance(usage, dict) else None
            raise LLMError(
                f"scoring model hit max_tokens (max_tokens={max_tokens}, "
                f"completion_tokens={_token_count(completion)})",
                truncated_content=content if isinstance(content, str) else "",
            )
        if not isinstance(content, str) or not content.strip():
            raise LLMError("scoring model returned empty content")
        return response

    @staticmethod
    def content(response: dict[str, Any]) -> str:
        return str(response["choices"][0]["message"]["content"])

    def _prompt_tokens(self, response: dict[str, Any]) -> int:
        usage = response.get("usage")
        tokens = _token_count(usage.get("prompt_tokens")) if isinstance(usage, dict) else 0
        return tokens if isinstance(tokens, int) else 0

    def vision_self_test(self) -> None:
        if self.model not in self.models():
            raise LLMError(f"scoring model alias {self.model!r} is not served")
        question = "What is the dominant background color? Answer with one word."
        answer = self.chat(
            [
                {
                    "role": "user",
                    "content": [
                        {"type": "text", "text": question},
                        {"type": "image_url", "image_url": {"url": _synthetic_image()}},
                    ],
                }
            ],
            max_tokens=128,
        )
        if not re.search(r"\bred\b", self.content(answer).lower()):
            raise LLMError("vision self-test returned the wrong color")
        text = self.chat([{"role": "user", "content": question}], max_tokens=128)
        if self._prompt_tokens(answer) <= self._prompt_tokens(text):
            raise LLMError("vision self-test saw no image tokens; the projector was ignored")
