"""The search guest's vsock query service and its gate ladder.

One connection carries one request line; one response line returns. The order is
fixed and every stage fails closed:

1. request schema (`v`, `op`, `query`, optional `id`);
2. DLP scan (`gates.static_verdict`) -- digit runs, emails, blobs, provider key
   shapes, keyword+value secrets and Shannon entropy, whitespace-normalised;
3. length cap (option, hard ceiling in `gates.MAX_QUERY_CHARS_HARD`);
4. persisted per-minute rate limit and daily budget (`limits.admit`);
5. Granite Guardian judge on CPU (any error, timeout or missing verdict blocks);
6. TinyFish request, then result stripping and bounds.

The journal line for a blocked query never contains the query text, only its
length, the rule id and a truncated digest. Allowed queries are logged verbatim,
because they already left the guest.
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Callable

import gates
import judge
import limits
import tinyfish

VMADDR_CID_ANY = 0xFFFFFFFF
MAX_LINE = 8192
MAX_LOG_BYTES = 1 << 20
MAX_ID_CHARS = 64
MAX_RESPONSE_BYTES = 8192
REQUEST_KEYS = {"v", "op", "query"}
OPTIONAL_KEYS = {"id"}


class ConfigError(RuntimeError):
    """The rendered configuration is unusable; the service refuses to start."""


@dataclass(frozen=True)
class Config:
    max_query_chars: int
    per_minute: int
    daily_budget: int
    judge_url: str
    judge_timeout: float
    search_url: str
    secret_path: str
    search_timeout: float
    state_path: str
    log_path: str
    max_results: int
    max_bytes: int


def _int(payload: dict[str, Any], key: str, low: int, high: int) -> int:
    value = payload.get(key)
    if not isinstance(value, int) or isinstance(value, bool) or not low <= value <= high:
        raise ConfigError(f"{key} must be an integer in {low}..{high}")
    return value


def _str(payload: dict[str, Any], key: str, prefix: str) -> str:
    value = payload.get(key)
    if not isinstance(value, str) or not value.startswith(prefix):
        raise ConfigError(f"{key} must be a string starting with {prefix!r}")
    return value


def _number(payload: dict[str, Any], key: str, low: float, high: float) -> float:
    value = payload.get(key)
    if not isinstance(value, (int, float)) or isinstance(value, bool) or not low <= value <= high:
        raise ConfigError(f"{key} must be a number in {low}..{high}")
    return float(value)


def load_config(path: str) -> Config:
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except OSError as exc:
        raise ConfigError(f"cannot read {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise ConfigError(f"{path} is not JSON: {exc}") from exc
    if not isinstance(data, dict) or data.get("version") != 1:
        raise ConfigError(f"{path} has an unsupported version")
    for section in ("gates", "judge", "search", "results"):
        if not isinstance(data.get(section), dict):
            raise ConfigError(f"{path} has no {section} section")
    gate_cfg = data["gates"]
    judge_cfg = data["judge"]
    search_cfg = data["search"]
    result_cfg = data["results"]
    state_path = data.get("state")
    log_path = data.get("log")
    if not isinstance(state_path, str) or not state_path.startswith("/"):
        raise ConfigError("state must be an absolute path")
    if not isinstance(log_path, str) or not log_path.startswith("/"):
        raise ConfigError("log must be an absolute path")
    return Config(
        max_query_chars=_int(
            gate_cfg, "max_query_chars", 1, gates.MAX_QUERY_CHARS_HARD
        ),
        per_minute=_int(gate_cfg, "per_minute", 1, 10000),
        daily_budget=_int(gate_cfg, "daily_budget", 1, 1000000),
        judge_url=_str(judge_cfg, "url", "http://127.0.0.1:"),
        judge_timeout=_number(judge_cfg, "timeout_s", 1, 120),
        search_url=_str(search_cfg, "url", "https://api.search.tinyfish.ai/"),
        secret_path=_str(search_cfg, "secret", "/run/"),
        search_timeout=_number(search_cfg, "timeout_s", 1, 120),
        state_path=state_path,
        log_path=log_path,
        max_results=_int(result_cfg, "max_results", 1, gates.MAX_RESULTS),
        max_bytes=_int(result_cfg, "max_bytes", 256, gates.MAX_RESULT_BYTES),
    )


class Journal:
    """Append-only root-only log, rotated at 1 MiB; every line also goes to stdout."""

    def __init__(self, path: str, max_bytes: int = MAX_LOG_BYTES) -> None:
        self.path = path
        self.max_bytes = max_bytes
        self.fd = self._open()
        self.written = os.stat(path).st_size

    def _open(self) -> int:
        fd = os.open(self.path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        os.chmod(self.path, 0o600)
        return fd

    def _rotate(self) -> None:
        os.close(self.fd)
        os.replace(self.path, self.path + ".1")
        self.fd = self._open()

    def write(self, record: dict[str, Any]) -> None:
        line = json.dumps(record, sort_keys=True, ensure_ascii=False) + "\n"
        encoded = line.encode("utf-8")
        if self.written + len(encoded) > self.max_bytes:
            self._rotate()
            self.written = 0
        os.write(self.fd, encoded)
        self.written += len(encoded)
        sys.stdout.write(line)
        sys.stdout.flush()


def _record(event: str, **fields: Any) -> dict[str, Any]:
    record = {
        "ts": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "unit": "searchd",
        "event": event,
    }
    record.update(fields)
    return record


def _block(reason: str, request_id: str | None) -> dict[str, Any]:
    response: dict[str, Any] = {
        "v": 1,
        "op": "search",
        "decision": "block",
        "reason": reason,
        "results": [],
        "truncated": False,
    }
    if request_id is not None:
        response["id"] = request_id
    return response


class SearchService:
    """The pipeline as a pure function of (request bytes, injected clients)."""

    def __init__(
        self,
        config: Config,
        *,
        journal: Journal | Callable[[dict[str, Any]], None],
        judge_fn: Callable[[str], str | None],
        search_fn: Callable[[str], dict[str, Any]],
        clock: Callable[[], float] = time.time,
    ) -> None:
        self.config = config
        self.journal = journal.write if isinstance(journal, Journal) else journal
        self.judge_fn = judge_fn
        self.search_fn = search_fn
        self.clock = clock
        self.call_limits = limits.Limits(config.per_minute, config.daily_budget)

    def _log(self, record: dict[str, Any]) -> None:
        try:
            self.journal(record)
        except OSError:
            # A failed append must not let a query through; the caller drops it.
            raise

    def _parse(self, raw: bytes) -> tuple[str, str | None] | None:
        if len(raw) > MAX_LINE:
            return None
        try:
            text = raw.decode("utf-8")
            request = json.loads(text)
        except (UnicodeDecodeError, json.JSONDecodeError):
            return None
        if not isinstance(request, dict):
            return None
        if set(request) - REQUEST_KEYS - OPTIONAL_KEYS or not REQUEST_KEYS <= set(request):
            return None
        if request.get("v") != 1 or request.get("op") != "search":
            return None
        query = request.get("query")
        request_id = request.get("id")
        if not isinstance(query, str):
            return None
        if request_id is not None and (
            not isinstance(request_id, str) or len(request_id) > MAX_ID_CHARS
        ):
            return None
        return query, request_id

    def handle(self, raw: bytes) -> dict[str, Any]:
        """Run the ladder for one request line and return the response object."""
        parsed = self._parse(raw)
        if parsed is None:
            self._log(_record("query", decision="block", reason="request", chars=len(raw), digest=""))
            return _block("request", None)
        query, request_id = parsed

        static = gates.static_verdict(query, self.config.max_query_chars)
        if not static.ok:
            self._log(
                _record(
                    "query",
                    decision="block",
                    reason=static.reason,
                    rule=static.rule,
                    chars=len(static.query),
                    digest=gates.fingerprint(static.query),
                )
            )
            return _block(static.reason, request_id)

        try:
            state = limits.load(self.config.state_path, self.clock())
        except limits.LimitError as exc:
            self._log(_record("error", reason="state", message=str(exc)))
            return _block("state", request_id)
        admitted, reason, next_state = limits.admit(state, self.clock(), self.call_limits)
        try:
            limits.save(self.config.state_path, next_state)
        except OSError as exc:
            self._log(_record("error", reason="state-write", message=str(exc)))
            return _block("state", request_id)
        if not admitted:
            self._log(
                _record(
                    "query",
                    decision="block",
                    reason=reason,
                    chars=len(static.query),
                    digest=gates.fingerprint(static.query),
                )
            )
            return _block(reason, request_id)

        try:
            verdict = self.judge_fn(gates.guardian_prompt(static.query))
        except judge.JudgeError as exc:
            self._log(_record("error", reason="judge", message=str(exc)))
            verdict = None
        if verdict == "yes":
            self._log(
                _record(
                    "query",
                    decision="block",
                    reason="judge",
                    rule="exfil-criterion",
                    chars=len(static.query),
                    digest=gates.fingerprint(static.query),
                )
            )
            return _block("judge", request_id)
        if verdict != "no":
            self._log(
                _record(
                    "query",
                    decision="block",
                    reason="judge",
                    rule="no-verdict",
                    chars=len(static.query),
                    digest=gates.fingerprint(static.query),
                )
            )
            return _block("judge", request_id)

        try:
            payload = self.search_fn(static.query)
            results, truncated = gates.sanitize_results(
                payload, self.config.max_results, self.config.max_bytes
            )
        except (tinyfish.SearchUpstreamError, ValueError) as exc:
            self._log(_record("error", reason="upstream", message=str(exc)))
            return _block("upstream", request_id)

        response = {
            "v": 1,
            "op": "search",
            "decision": "allow",
            "reason": "ok",
            "results": results,
            "truncated": truncated,
        }
        if request_id is not None:
            response["id"] = request_id
        self._log(
            _record(
                "query",
                decision="allow",
                reason="ok",
                chars=len(static.query),
                digest=gates.fingerprint(static.query),
                query=static.query,
                results=len(results),
                truncated=truncated,
            )
        )
        return response


def default_judge(config: Config) -> Callable[[str], str | None]:
    def run(prompt: str) -> str | None:
        return gates.parse_verdict(judge.ask(prompt, config.judge_url, config.judge_timeout))

    return run


def default_search(config: Config, api_key: str) -> Callable[[str], dict[str, Any]]:
    def run(query: str) -> dict[str, Any]:
        return tinyfish.search(query, api_key, config.search_url, config.search_timeout)

    return run


def serve(config: Config, port: int) -> None:
    journal = Journal(config.log_path)
    api_key = tinyfish.read_api_key(config.secret_path)
    service = SearchService(
        config,
        journal=journal,
        judge_fn=default_judge(config),
        search_fn=default_search(config, api_key),
    )
    server = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((VMADDR_CID_ANY, port))
    server.listen(4)
    journal.write(_record("listen", port=port, max_chars=config.max_query_chars))
    while True:
        conn, _ = server.accept()
        with conn:
            conn.settimeout(10)
            data = b""
            try:
                while b"\n" not in data and len(data) < MAX_LINE:
                    chunk = conn.recv(MAX_LINE)
                    if not chunk:
                        break
                    data += chunk
                if b"\n" in data:
                    data = data.split(b"\n", 1)[0]
                response = service.handle(data)
                encoded = (json.dumps(response, ensure_ascii=False, sort_keys=True) + "\n").encode("utf-8")
                if len(encoded) > MAX_RESPONSE_BYTES:
                    encoded = (json.dumps(_block("internal", None)) + "\n").encode("utf-8")
                conn.sendall(encoded)
            except (OSError, limits.LimitError) as exc:
                journal.write(_record("error", reason="connection", message=str(exc)))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="searchd")
    parser.add_argument("--config", required=True)
    parser.add_argument("--port", type=int, required=True)
    args = parser.parse_args(argv)
    try:
        config = load_config(args.config)
        serve(config, args.port)
    except (ConfigError, tinyfish.SearchUpstreamError, OSError) as exc:
        print(f"searchd: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
