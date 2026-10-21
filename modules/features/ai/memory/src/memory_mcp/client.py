"""MCP streamable-HTTP client used by the shim, the CLI, and the wrapper."""

from __future__ import annotations

from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from typing import AsyncIterator

import httpx
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client
from mcp.types import Prompt, TextContent, Tool


class UpstreamError(RuntimeError):
    """The memory server could not be reached or returned an error."""


@dataclass(frozen=True)
class ClientConfig:
    url: str
    headers: tuple[tuple[str, str], ...] = field(default_factory=tuple)
    timeout: float = 75.0
    connect_timeout: float = 5.0

    def header_dict(self) -> dict[str, str]:
        return dict(self.headers)


@dataclass(frozen=True)
class ToolResult:
    text: str
    is_error: bool
    structured: dict[str, object] | None = None


def _result_text(result: object) -> str:
    parts: list[str] = []
    for block in getattr(result, "content", []) or []:
        text = getattr(block, "text", None)
        if isinstance(block, TextContent) and text:
            parts.append(text)
    return "\n".join(parts)


@asynccontextmanager
async def open_session(config: ClientConfig) -> AsyncIterator[ClientSession]:
    timeout = httpx.Timeout(config.timeout, connect=config.connect_timeout, read=config.timeout)
    try:
        async with httpx.AsyncClient(
            headers=config.header_dict(),
            timeout=timeout,
            follow_redirects=True,
        ) as client:
            async with streamable_http_client(config.url, http_client=client) as (read, write, _):
                async with ClientSession(read, write) as session:
                    await session.initialize()
                    yield session
    except UpstreamError:
        raise
    except Exception as exc:  # httpx, anyio, and MCP all surface differently
        raise UpstreamError(f"{type(exc).__name__}: {exc}") from exc


async def call_tool(config: ClientConfig, name: str, arguments: dict[str, object]) -> ToolResult:
    async with open_session(config) as session:
        result = await session.call_tool(name, arguments)
    return ToolResult(
        text=_result_text(result),
        is_error=bool(getattr(result, "isError", False)),
        structured=getattr(result, "structuredContent", None),
    )


async def list_tools(config: ClientConfig) -> list[Tool]:
    async with open_session(config) as session:
        result = await session.list_tools()
    return list(result.tools)


async def list_prompts(config: ClientConfig) -> list[Prompt]:
    async with open_session(config) as session:
        result = await session.list_prompts()
    return list(result.prompts)
