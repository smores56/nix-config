"""TinyFish Search client for the search guest.

The guest holds exactly one credential, `TINYFISH_API_KEY`, read from the
read-only secret device. Requests leave through the tap's only allowlisted name,
`api.search.tinyfish.ai`, via the host proxy in `HTTP(S)_PROXY`. Any error
raises SearchUpstreamError and the query is answered with a block: results are
never synthesised or partially returned.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

API_KEY_ENV = "TINYFISH_API_KEY"
DEFAULT_URL = "https://api.search.tinyfish.ai/"
DEFAULT_TIMEOUT = 15.0
MAX_BODY_BYTES = 1 << 20


class SearchUpstreamError(RuntimeError):
    """The search provider refused, timed out or returned an unusable document."""


def read_api_key(path: str) -> str:
    """Parse the secret contract strictly: exactly one `TINYFISH_API_KEY=` line."""
    try:
        with open(path, encoding="utf-8") as handle:
            lines = [line.strip() for line in handle.read().splitlines() if line.strip()]
    except OSError as exc:
        raise SearchUpstreamError(f"secret {path} is unreadable: {exc}") from exc
    if len(lines) != 1:
        raise SearchUpstreamError("secret contract must contain exactly one line")
    name, sep, value = lines[0].partition("=")
    if sep != "=" or name != API_KEY_ENV:
        raise SearchUpstreamError(f"secret contract must be {API_KEY_ENV}=<key>")
    if not 20 <= len(value) <= 512 or any(ch.isspace() for ch in value):
        raise SearchUpstreamError("secret value has an unexpected shape")
    return value


def _opener() -> urllib.request.OpenerDirector:
    # The default opener honours HTTP(S)_PROXY, which is the tap's host proxy.
    return urllib.request.build_opener()


def request_url(base: str, query: str) -> str:
    parsed = urllib.parse.urlsplit(base)
    if parsed.scheme != "https" or parsed.hostname != "api.search.tinyfish.ai":
        raise SearchUpstreamError(f"search base url {base!r} is not the TinyFish API")
    return base + "?" + urllib.parse.urlencode({"query": query})


def search(
    query: str,
    api_key: str,
    base: str = DEFAULT_URL,
    timeout: float = DEFAULT_TIMEOUT,
    opener: urllib.request.OpenerDirector | None = None,
) -> dict[str, Any]:
    if not isinstance(api_key, str) or not api_key:
        raise SearchUpstreamError("missing API key")
    if timeout <= 0:
        raise SearchUpstreamError("timeout must be positive")
    url = request_url(base, query)
    request = urllib.request.Request(
        url,
        headers={"X-API-Key": api_key, "Accept": "application/json"},
        method="GET",
    )
    try:
        with (opener or _opener()).open(request, timeout=timeout) as response:
            if response.status != 200:
                raise SearchUpstreamError(f"search returned HTTP {response.status}")
            raw = response.read(MAX_BODY_BYTES + 1)
    except urllib.error.HTTPError as exc:
        raise SearchUpstreamError(f"search returned HTTP {exc.code}") from exc
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise SearchUpstreamError(f"search is unreachable: {exc}") from exc
    if len(raw) > MAX_BODY_BYTES:
        raise SearchUpstreamError("search response exceeds the body cap")
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise SearchUpstreamError("search response is not JSON") from exc
    if not isinstance(payload, dict):
        raise SearchUpstreamError("search response is not an object")
    return payload
