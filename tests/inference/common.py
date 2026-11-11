"""Shared plumbing for the kanbei inference eval (Python stdlib only).

The harness runs inside the guest, where the lanes are loopback-only. Every script skips with
exit code 0 when its endpoint is absent or the model file named by the manifest is not there,
so the suite is safe to run before the GPU cutover and before the weight download.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

DEFAULT_CHAT_URL = "http://127.0.0.1:8090"
# A second chat server with f16 KV (`-ctk f16 -ctv f16`), used only by the quality comparison.
DEFAULT_FP16_URL = "http://127.0.0.1:8093"

DEFAULT_MODELS_DIR = Path("/var/lib/kanbei/models")
DEFAULT_CGROUP = Path("/sys/fs/cgroup/system.slice/kanbei-chat.service/memory.events")
MANIFEST = Path(__file__).resolve().parents[2] / "modules/lib/kanbei-models.json"

# Nominal lane request sizes; the unified pool serves them breadth-first (see the doc).
LANES = (
    ("chat", 131072),
    ("loop-a", 32768),
    ("loop-b", 32768),
    ("loop-c", 32768),
)

# One chat token is roughly 3.6 characters for English prose; prompts are corrected against
# /tokenize before they are sent.
CHARS_PER_TOKEN = 3.6


class Skip(Exception):
    """The eval cannot run here; the caller prints the reason and exits 0."""


def http_json(
    url: str,
    payload: dict[str, Any] | None = None,
    timeout: float = 30.0,
    method: str | None = None,
) -> tuple[int, Any]:
    """Return (status, decoded body or raw text). Raises OSError on transport failure."""
    data = None
    headers = {"Accept": "application/json"}
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = response.read().decode("utf-8", "replace")
            status = response.status
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", "replace")
        status = exc.code
    try:
        return status, json.loads(body)
    except json.JSONDecodeError:
        return status, body


def health(base_url: str, timeout: float = 3.0) -> bool:
    try:
        status, body = http_json(f"{base_url.rstrip('/')}/health", timeout=timeout)
    except OSError:
        return False
    return status == 200 and isinstance(body, dict) and body.get("status") == "ok"


def metrics(base_url: str, timeout: float = 3.0) -> dict[str, float]:
    """Prometheus text -> {name: value}; empty when the endpoint has no metrics."""
    try:
        request = urllib.request.Request(f"{base_url.rstrip('/')}/metrics")
        with urllib.request.urlopen(request, timeout=timeout) as response:
            text = response.read().decode("utf-8", "replace")
    except OSError:
        return {}
    values: dict[str, float] = {}
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        name, _, raw = line.partition(" ")
        try:
            values[name] = float(raw.strip())
        except ValueError:
            continue
    return values


def load_manifest(path: Path = MANIFEST) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def missing_models(models_dir: Path, manifest_path: Path = MANIFEST) -> list[str]:
    """Files the manifest promises but the directory does not hold (size-checked)."""
    try:
        manifest = load_manifest(manifest_path)
    except (OSError, json.JSONDecodeError) as exc:
        return [f"manifest {manifest_path}: {exc}"]
    missing = []
    for name, spec in manifest["models"].items():
        target = models_dir / spec["file"]
        if not target.is_file():
            missing.append(f"{name}: {target} is missing")
        elif target.stat().st_size != spec["size"]:
            missing.append(f"{name}: {target} has the wrong size")
    return missing


def require_endpoint(base_url: str, models_dir: Path | None, manifest_path: Path = MANIFEST) -> None:
    if not health(base_url):
        raise Skip(f"no healthy llama-server at {base_url}")
    if models_dir is not None:
        missing = missing_models(models_dir, manifest_path)
        if missing:
            raise Skip("model files not downloaded: " + "; ".join(missing))


def filler_text(chars: int, seed: str = "kanbei") -> str:
    """Deterministic prose of roughly `chars` characters."""
    base = (
        "The archive room kept its ledgers in order, shelf after shelf, and every entry was "
        "checked twice against the day's receipts. Wind moved through the high windows while "
        "the clerk copied figures into a narrower hand, and the clock above the door kept time "
        "with the ferry below. "
    ).replace("\n", " ")
    unit = f"{seed}: {base}"
    repeat = max(1, chars // len(unit) + 1)
    return (unit * repeat)[:chars]


def token_count(base_url: str, text: str, timeout: float = 120.0) -> int | None:
    """Exact token count through llama-server's /tokenize; None when unavailable."""
    try:
        status, body = http_json(
            f"{base_url.rstrip('/')}/tokenize",
            {"content": text, "add_special": False},
            timeout=timeout,
        )
    except OSError:
        return None
    if status != 200 or not isinstance(body, dict) or "tokens" not in body:
        return None
    return len(body["tokens"])


def prompt_for_tokens(
    base_url: str,
    target: int,
    seed: str,
    timeout: float = 120.0,
    max_rounds: int = 4,
) -> tuple[str, int | None]:
    """Grow a filler prompt until /tokenize reports at least `target` tokens."""
    chars = max(1, int(target * CHARS_PER_TOKEN))
    text = filler_text(chars, seed)
    count = token_count(base_url, text, timeout=timeout)
    rounds = 0
    while count is not None and count < target and rounds < max_rounds:
        chars = int(chars * (target / max(1, count)) * 1.02)
        text = filler_text(chars, seed)
        count = token_count(base_url, text, timeout=timeout)
        rounds += 1
    return text, count


def chat_completion(
    base_url: str,
    prompt: str,
    max_tokens: int = 16,
    timeout: float = 1800.0,
    temperature: float = 0.0,
) -> tuple[int, Any, float]:
    """POST /v1/chat/completions; returns (status, body, seconds)."""
    import time

    started = time.monotonic()
    try:
        status, body = http_json(
            f"{base_url.rstrip('/')}/v1/chat/completions",
            {
                "messages": [{"role": "user", "content": prompt}],
                "max_tokens": max_tokens,
                "temperature": temperature,
                "stream": False,
            },
            timeout=timeout,
        )
    except OSError as exc:
        return 0, str(exc), time.monotonic() - started
    return status, body, time.monotonic() - started


def completion_text(body: Any) -> str:
    try:
        return body["choices"][0]["message"]["content"] or ""
    except (KeyError, IndexError, TypeError):
        return ""


def oom_kills(cgroup: Path = DEFAULT_CGROUP) -> int | None:
    """memory.events oom_kill counter, when the cgroup exists and is readable."""
    try:
        for line in cgroup.read_text(encoding="utf-8").splitlines():
            key, _, value = line.partition(" ")
            if key == "oom_kill":
                return int(value)
    except (OSError, ValueError):
        return None
    return None


def emit(result: dict[str, Any], path: Path | None) -> None:
    text = json.dumps(result, indent=2, sort_keys=True)
    if path is not None:
        path.write_text(text + "\n", encoding="utf-8")
    print(text)


