"""Client for the guest-local Granite Guardian server.

The judge runs as a loopback llama.cpp server inside the search guest; this
module only builds the request and parses the verdict. Every failure mode --
connection refused, timeout, non-200, malformed JSON, no verdict -- raises
JudgeError, and `searchd` blocks the query. The proxy environment is bypassed so
the judge request can never leave the guest.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.request
from typing import Any

DEFAULT_TIMEOUT = 20.0
MAX_BODY_BYTES = 1 << 20


class JudgeError(RuntimeError):
    """The judge did not return a usable verdict."""


def _opener() -> urllib.request.OpenerDirector:
    return urllib.request.build_opener(urllib.request.ProxyHandler({}))


def _request_body(prompt: str) -> dict[str, Any]:
    # Greedy decoding: temperature 0 with a single-token top-k keeps the verdict
    # reproducible, and a short bound stops a runaway completion.
    return {
        "prompt": prompt,
        "temperature": 0,
        "top_k": 1,
        "top_p": 1,
        "n_predict": 16,
        "stream": False,
        "cache_prompt": False,
        "stop": ["<|end_of_text|>"],
    }


def ask(
    prompt: str,
    url: str,
    timeout: float = DEFAULT_TIMEOUT,
    opener: urllib.request.OpenerDirector | None = None,
) -> str | None:
    """POST the prompt and return the judge's raw completion text."""
    if not isinstance(url, str) or not url.startswith(("http://127.0.0.1", "http://localhost")):
        raise JudgeError(f"judge url {url!r} is not loopback")
    if timeout <= 0:
        raise JudgeError("judge timeout must be positive")
    body = json.dumps(_request_body(prompt)).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=body,
        headers={"Content-Type": "application/json", "Accept": "application/json"},
        method="POST",
    )
    try:
        with (opener or _opener()).open(request, timeout=timeout) as response:
            if response.status != 200:
                raise JudgeError(f"judge returned HTTP {response.status}")
            raw = response.read(MAX_BODY_BYTES + 1)
    except urllib.error.HTTPError as exc:
        raise JudgeError(f"judge returned HTTP {exc.code}") from exc
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise JudgeError(f"judge is unreachable: {exc}") from exc
    if len(raw) > MAX_BODY_BYTES:
        raise JudgeError("judge response exceeds the body cap")
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise JudgeError("judge response is not JSON") from exc
    if not isinstance(payload, dict) or not isinstance(payload.get("content"), str):
        raise JudgeError("judge response has no content")
    return payload["content"]
