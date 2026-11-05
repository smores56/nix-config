"""Serve OpenAI chat completions with headless Claude Code.

The work machine has a Claude subscription and no API key, so extraction runs
`claude -p` on the subscription. The invocation is locked down: no tools, no MCP
servers, no settings files and no session transcript, so an episode's text can
only be read, never acted on. The prompt goes on stdin because episodes can be
large and must not appear in the process list.
"""

from __future__ import annotations

import asyncio
import json
import os
import time
from dataclasses import dataclass
from typing import Any, Mapping

DEFAULT_MODEL = "claude-haiku-5-5"
DEFAULT_TIMEOUT = 300.0
MODEL_ENV = "MEMORY_CLAUDE_MODEL"
BINARY_ENV = "MEMORY_CLAUDE_BIN"
TIMEOUT_ENV = "MEMORY_CLAUDE_TIMEOUT"
# The native installer's location; claude is installed outside Nix and launchd has a bare PATH.
USER_INSTALL = ".local/bin/claude"


class ClaudeError(RuntimeError):
    """Claude could not produce a usable answer."""


class ClaudeTimeout(ClaudeError):
    """Claude did not answer before the deadline."""


# The child needs HOME for its credential store and the proxy variables to reach the API; nothing
# else of the proxy's environment (notably the upstream key's neighbours) is passed on.
ENV_ALLOWLIST = (
    "HOME",
    "PATH",
    "TMPDIR",
    "LANG",
    "LC_ALL",
    "USER",
    "LOGNAME",
    "HTTPS_PROXY",
    "HTTP_PROXY",
    "NO_PROXY",
    "ALL_PROXY",
    "https_proxy",
    "http_proxy",
    "no_proxy",
    "all_proxy",
    "SSL_CERT_FILE",
    "NIX_SSL_CERT_FILE",
)


@dataclass(frozen=True)
class ClaudeConfig:
    binary: str
    model: str = DEFAULT_MODEL
    timeout: float = DEFAULT_TIMEOUT
    # Extra variable names to forward; a test seam.
    passthrough: tuple[str, ...] = ()


def child_environment(config: ClaudeConfig, environ: Mapping[str, str] | None = None) -> dict[str, str]:
    env = os.environ if environ is None else environ
    return {name: env[name] for name in (*ENV_ALLOWLIST, *config.passthrough) if name in env}


def check_binary(config: ClaudeConfig) -> None:
    """Fail early when the configured binary cannot be run."""
    if not (os.path.isfile(config.binary) and os.access(config.binary, os.X_OK)):
        raise ClaudeError(f"claude is not an executable file at {config.binary}")


def resolve_binary(environ: Mapping[str, str], *, home: str) -> str:
    return environ.get(BINARY_ENV) or os.path.join(home, USER_INSTALL)


def config_from_env(environ: Mapping[str, str] | None = None) -> ClaudeConfig:
    env = os.environ if environ is None else environ
    return ClaudeConfig(
        binary=resolve_binary(env, home=env.get("HOME") or os.path.expanduser("~")),
        model=env.get(MODEL_ENV) or DEFAULT_MODEL,
        timeout=float(env.get(TIMEOUT_ENV) or DEFAULT_TIMEOUT),
    )


def _text(content: Any) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(
            part["text"] for part in content if isinstance(part, dict) and isinstance(part.get("text"), str)
        )
    return ""


def split_messages(messages: Any) -> tuple[str, str]:
    """System text for `--system-prompt` and the remaining turns for stdin."""
    items = [m for m in messages if isinstance(m, dict)] if isinstance(messages, list) else []
    system = "\n\n".join(_text(m.get("content")) for m in items if m.get("role") in ("system", "developer"))
    turns = [(m.get("role", "user"), _text(m.get("content"))) for m in items if m.get("role") not in ("system", "developer")]
    if len(turns) == 1:
        return system, turns[0][1]
    return system, "\n\n".join(f"{role}: {text}" for role, text in turns)


def response_schema(body: Mapping[str, Any]) -> dict[str, Any] | None:
    fmt = body.get("response_format")
    if not isinstance(fmt, dict) or fmt.get("type") != "json_schema":
        return None
    schema = (fmt.get("json_schema") or {}).get("schema")
    return schema if isinstance(schema, dict) else None


def build_argv(config: ClaudeConfig, system: str, schema: Mapping[str, Any] | None) -> list[str]:
    return [
        config.binary,
        "-p",
        "--model",
        config.model,
        *(["--system-prompt", system] if system else []),
        "--tools",
        "",
        "--strict-mcp-config",
        "--setting-sources",
        "",
        "--no-session-persistence",
        "--output-format",
        "json",
        *(["--json-schema", json.dumps(schema, separators=(",", ":"))] if schema is not None else []),
    ]


def parse_output(stdout: str, *, structured: bool) -> tuple[str, Mapping[str, Any]]:
    """The message content and token usage from one `--output-format json` result."""
    try:
        result = json.loads(stdout)
    except json.JSONDecodeError as exc:
        raise ClaudeError(f"claude printed unparseable output ({len(stdout)} bytes)") from exc
    if not isinstance(result, dict):
        raise ClaudeError("claude printed a non-object result")
    if result.get("is_error"):
        raise ClaudeError("claude reported is_error")
    usage = result.get("usage") if isinstance(result.get("usage"), dict) else {}
    if structured:
        if result.get("structured_output") is None:
            raise ClaudeError("claude returned no structured_output for the requested schema")
        return json.dumps(result["structured_output"], ensure_ascii=False), usage
    text = result.get("result")
    if not isinstance(text, str):
        raise ClaudeError("claude returned no result text")
    return text, usage


def completion(model: str, content: str, usage: Mapping[str, Any], *, created: int) -> dict[str, Any]:
    prompt = int(usage.get("input_tokens") or 0)
    answer = int(usage.get("output_tokens") or 0)
    return {
        "id": f"chatcmpl-claude-{created}",
        "object": "chat.completion",
        "created": created,
        "model": model,
        "choices": [
            {"index": 0, "message": {"role": "assistant", "content": content}, "finish_reason": "stop"}
        ],
        "usage": {"prompt_tokens": prompt, "completion_tokens": answer, "total_tokens": prompt + answer},
    }


async def _run(config: ClaudeConfig, argv: list[str], prompt: str) -> str:
    try:
        process = await asyncio.create_subprocess_exec(
            *argv,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env=child_environment(config),
        )
    except OSError as exc:
        raise ClaudeError(f"cannot run claude at {argv[0]}: {type(exc).__name__}") from exc
    try:
        stdout, stderr = await asyncio.wait_for(process.communicate(prompt.encode("utf-8")), config.timeout)
    except asyncio.TimeoutError as exc:
        raise ClaudeTimeout(f"claude did not answer within {config.timeout:g}s") from exc
    finally:
        # A timeout and a caller that went away both leave the child running; its permit is
        # released with this frame, so it must not outlive it.
        if process.returncode is None:
            process.kill()
            await process.wait()
    if process.returncode != 0:
        raise ClaudeError(f"claude exited {process.returncode} ({len(stderr)} bytes of stderr)")
    return stdout.decode("utf-8", "replace")


async def complete(config: ClaudeConfig, body: Mapping[str, Any], *, now: int | None = None) -> dict[str, Any]:
    """Answer one chat-completions request body, or raise `ClaudeError`."""
    system, prompt = split_messages(body.get("messages"))
    schema = response_schema(body)
    stdout = await _run(config, build_argv(config, system, schema), prompt)
    content, usage = parse_output(stdout, structured=schema is not None)
    return completion(config.model, content, usage, created=int(time.time()) if now is None else now)
