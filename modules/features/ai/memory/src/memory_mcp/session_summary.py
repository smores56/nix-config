"""Summarize one Maki session with the extraction model.

The model is Neuralwatt `deepseek-v4.1-flash`, reached through the loopback
gateway that owns the account key (see `llm_proxy.py`), so this client sends no
credential. The gateway also turns reasoning off: a reasoning model spends its
whole token budget thinking and returns no content.

The request asks for `json_object` output with a fixed shape (a prose summary
plus explicit decisions, constraints, errors, and user preferences) and a
temperature of 0. Parsing is defensive because the model is a text generator:
the answer may be fenced, a list entry may be a bare string, and a missing
`usage` block must not fail the session. One retry covers a malformed answer or
a transient gateway error; a 4xx means the request itself is wrong and is not
retried. A session that still fails is reported and skipped; it never fails the
run.
"""

from __future__ import annotations

import json
import os
import time
from dataclasses import dataclass
from typing import Callable

import httpx

DEFAULT_LLM_URL = "http://127.0.0.1:8082"
DEFAULT_MODEL = "deepseek-v4.1-flash"
# Neuralwatt deepseek-v4.1-flash list prices, USD per million tokens.
DEFAULT_INPUT_PRICE = 0.15
DEFAULT_OUTPUT_PRICE = 0.60
DEFAULT_TIMEOUT = 300.0
RETRIES = 1
# A transcript is already bounded by the session budget; this is only defence
# against a caller passing raw text.
MAX_PROMPT_CHARS = 120_000
MAX_SUMMARY_CHARS = 4_000
MAX_ITEMS_PER_CATEGORY = 8
MAX_HEADING_CHARS = 80
MAX_DETAIL_CHARS = 1_200
MIN_SUMMARY_CHARS = 40
# Statuses that mean "the request is wrong", not "try again".
FATAL_STATUSES = frozenset({400, 401, 403, 404, 405, 413, 422})

SYSTEM_PROMPT = """\
You turn one coding-agent session transcript into durable project memory.
Reason over the conversation, not over the raw JSON you were given.

Return one JSON object with exactly these keys:
- "summary": a 150-300 word prose summary of what was done, decided, and left open.
- "decisions": explicit choices that were made ("Use uv", "Keep the registry as the source of truth").
- "constraints": rules, limits, or requirements that were stated ("No sudo", "Target Python 3.12").
- "errors": failures that were hit and the lesson learned ("nix fmt failed on a stale lock; deleting it fixed the run").
- "preferences": user-stated preferences about style, tools, or workflow.

Each list item is {"heading": "<at most 80 characters>", "detail": "<one to three sentences>"}.
Quote paths, commands, error strings, and identifiers verbatim inside detail.
Only include items that were stated explicitly in the transcript; never infer
or invent. Use an empty list when a category does not appear.
"""


class SummaryError(RuntimeError):
    """The gateway could not produce a usable summary for one session."""


@dataclass(frozen=True)
class SummaryItem:
    heading: str
    detail: str


@dataclass(frozen=True)
class Extraction:
    """A parsed model answer: the prose summary plus the typed lists."""

    summary: str
    decisions: tuple[SummaryItem, ...] = ()
    constraints: tuple[SummaryItem, ...] = ()
    errors: tuple[SummaryItem, ...] = ()
    preferences: tuple[SummaryItem, ...] = ()


@dataclass(frozen=True)
class SummaryResult:
    extraction: Extraction
    prompt_tokens: int
    completion_tokens: int
    attempts: int
    wall_seconds: float
    model: str


@dataclass(frozen=True)
class Prices:
    input_per_million: float = DEFAULT_INPUT_PRICE
    output_per_million: float = DEFAULT_OUTPUT_PRICE


def prices_from_env() -> Prices:
    """Prices are configurable so a model or list-price change needs no code edit."""

    def read(name: str, default: float) -> float:
        raw = os.environ.get(name, "").strip()
        if not raw:
            return default
        try:
            value = float(raw)
        except ValueError:
            return default
        return value if value >= 0 else default

    return Prices(
        input_per_million=read("MEMORY_SUMMARY_PRICE_IN", DEFAULT_INPUT_PRICE),
        output_per_million=read("MEMORY_SUMMARY_PRICE_OUT", DEFAULT_OUTPUT_PRICE),
    )


def cost_usd(prompt_tokens: int, completion_tokens: int, input_price: float, output_price: float) -> float:
    return prompt_tokens / 1_000_000 * input_price + completion_tokens / 1_000_000 * output_price


def _one_line(value: object, limit: int) -> str:
    return " ".join(str(value or "").split())[:limit].strip()


def _item_heading(entry: dict[str, object], detail: str) -> str:
    for key in ("heading", "title", "name"):
        heading = _one_line(entry.get(key), MAX_HEADING_CHARS)
        if heading:
            return heading
    return _one_line(detail, MAX_HEADING_CHARS)


def _coerce_items(value: object) -> tuple[SummaryItem, ...]:
    if not isinstance(value, list):
        return ()
    items: list[SummaryItem] = []
    for entry in value:
        if isinstance(entry, str):
            detail = entry.strip()[:MAX_DETAIL_CHARS]
            heading = _one_line(detail, MAX_HEADING_CHARS)
        elif isinstance(entry, dict):
            detail = str(entry.get("detail") or entry.get("text") or entry.get("description") or "").strip()
            detail = detail[:MAX_DETAIL_CHARS]
            heading = _item_heading(entry, detail)
        else:
            continue
        if not detail or not heading:
            continue
        items.append(SummaryItem(heading=heading, detail=detail))
        if len(items) >= MAX_ITEMS_PER_CATEGORY:
            break
    return tuple(items)


def _strip_fences(text: str) -> str:
    stripped = text.strip()
    if not stripped.startswith("```"):
        return stripped
    lines = stripped.splitlines()
    if lines and lines[0].startswith("```"):
        lines = lines[1:]
    if lines and lines[-1].strip().startswith("```"):
        lines = lines[:-1]
    return "\n".join(lines).strip()


def _load_object(text: str) -> dict[str, object]:
    candidate = _strip_fences(text)
    try:
        payload = json.loads(candidate)
    except json.JSONDecodeError:
        start, end = candidate.find("{"), candidate.rfind("}")
        if start < 0 or end <= start:
            raise SummaryError(f"model answer is not JSON: {candidate[:120]!r}") from None
        try:
            payload = json.loads(candidate[start : end + 1])
        except json.JSONDecodeError as exc:
            raise SummaryError(f"model answer is not JSON: {exc}") from exc
    if not isinstance(payload, dict):
        raise SummaryError("model answer is not a JSON object")
    return payload


def parse_summary(text: str) -> Extraction:
    """Parse one model answer, or raise `SummaryError` when it is unusable."""
    payload = _load_object(text)
    summary = payload.get("summary")
    if not isinstance(summary, str):
        raise SummaryError("model answer has no summary string")
    cleaned = summary.strip()[:MAX_SUMMARY_CHARS]
    if len(cleaned) < MIN_SUMMARY_CHARS:
        raise SummaryError(f"model answer summary is too short ({len(cleaned)} chars)")
    return Extraction(
        summary=cleaned,
        decisions=_coerce_items(payload.get("decisions")),
        constraints=_coerce_items(payload.get("constraints")),
        errors=_coerce_items(payload.get("errors")),
        preferences=_coerce_items(payload.get("preferences")),
    )


def _message_content(payload: object) -> str:
    if not isinstance(payload, dict):
        raise SummaryError("gateway answer is not an object")
    choices = payload.get("choices")
    if not isinstance(choices, list) or not choices or not isinstance(choices[0], dict):
        raise SummaryError("gateway answer has no choices")
    message = choices[0].get("message")
    if not isinstance(message, dict):
        raise SummaryError("gateway answer has no message")
    content = message.get("content")
    if isinstance(content, list):
        content = "".join(
            str(part.get("text") or "")
            for part in content
            if isinstance(part, dict) and part.get("type") in (None, "text")
        )
    if not isinstance(content, str) or not content.strip():
        raise SummaryError("gateway answer has no content")
    return content


def _token_count(usage: object, *names: str) -> int:
    if not isinstance(usage, dict):
        return 0
    for name in names:
        value = usage.get(name)
        if isinstance(value, bool):
            continue
        if isinstance(value, (int, float)):
            return max(0, int(value))
    return 0


class SummaryClient:
    """One loopback client; `transport` is the test seam for the gateway."""

    def __init__(
        self,
        *,
        url: str | None = None,
        model: str | None = None,
        timeout: float | None = None,
        retries: int = RETRIES,
        transport: httpx.AsyncBaseTransport | None = None,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self.url = (url or os.environ.get("MEMORY_LLM_URL", "").strip() or DEFAULT_LLM_URL).rstrip("/")
        self.model = model or os.environ.get("MEMORY_SUMMARY_MODEL", "").strip() or DEFAULT_MODEL
        self.timeout = timeout or DEFAULT_TIMEOUT
        self.retries = retries
        self._transport = transport
        self._client: httpx.AsyncClient | None = None
        self._clock = clock

    async def __aenter__(self) -> SummaryClient:
        self._http()
        return self

    async def __aexit__(self, *exc: object) -> None:
        await self.aclose()

    def _http(self) -> httpx.AsyncClient:
        if self._client is None:
            self._client = httpx.AsyncClient(
                base_url=self.url, timeout=self.timeout, transport=self._transport
            )
        return self._client

    async def aclose(self) -> None:
        if self._client is not None:
            await self._client.aclose()
            self._client = None

    def _payload(self, transcript: str) -> dict[str, object]:
        return {
            "model": self.model,
            "temperature": 0,
            "response_format": {"type": "json_object"},
            "messages": [
                {"role": "system", "content": SYSTEM_PROMPT},
                {
                    "role": "user",
                    "content": "Session transcript:\n\n" + transcript[:MAX_PROMPT_CHARS],
                },
            ],
        }

    async def summarize(self, transcript: str) -> SummaryResult:
        """Summarize one transcript; retries once, then raises `SummaryError`."""
        body = self._payload(transcript)
        started = self._clock()
        attempts = 0
        last_error = "no attempt was made"
        while attempts <= self.retries:
            attempts += 1
            try:
                response = await self._http().post("/v1/chat/completions", json=body)
            except httpx.HTTPError as exc:
                last_error = f"gateway unreachable at {self.url}: {type(exc).__name__}: {exc}"
                continue
            if response.status_code != 200:
                detail = response.text.strip()[:200]
                last_error = f"gateway returned HTTP {response.status_code}: {detail}"
                if response.status_code in FATAL_STATUSES:
                    raise SummaryError(last_error)
                continue
            try:
                payload = response.json()
            except ValueError:
                last_error = "gateway returned invalid JSON"
                continue
            try:
                extraction = parse_summary(_message_content(payload))
            except SummaryError as exc:
                last_error = str(exc)
                continue
            usage = payload.get("usage") if isinstance(payload, dict) else None
            return SummaryResult(
                extraction=extraction,
                prompt_tokens=_token_count(usage, "prompt_tokens", "input_tokens"),
                completion_tokens=_token_count(usage, "completion_tokens", "output_tokens"),
                attempts=attempts,
                wall_seconds=round(self._clock() - started, 3),
                model=self.model,
            )
        raise SummaryError(last_error)
