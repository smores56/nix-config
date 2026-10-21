"""Stdio MCP shim launched by Maki.

Maki's HTTP MCP client sends no cwd and no roots, but its stdio client inherits
Maki's process cwd. This shim derives the project group there, refuses work
before it ever dials the server, and proxies the MCP surface with the group and
cwd as headers. The model never sees a group argument.
"""

from __future__ import annotations

import argparse
import os
import sys
from dataclasses import dataclass
from typing import Any, Awaitable, Callable

import anyio
from mcp.server.lowlevel import Server
from mcp.server.stdio import stdio_server
from mcp.types import CallToolResult, Prompt, TextContent, Tool

from . import client
from .client import ClientConfig, ToolResult, UpstreamError
from .groups import GroupRefused, derive_group
from .schema import FALLBACK_TOOLS

DEFAULT_URL = "http://127.0.0.1:8182/mcp"
DEFAULT_TIMEOUT = 75.0

ListToolsFn = Callable[[ClientConfig], Awaitable[list[Tool]]]
CallToolFn = Callable[[ClientConfig, str, dict[str, object]], Awaitable[ToolResult]]
ListPromptsFn = Callable[[ClientConfig], Awaitable[list[Prompt]]]


@dataclass(frozen=True)
class ShimConfig:
    group: str
    cwd: str
    url: str = DEFAULT_URL
    actor: str = "maki"
    timeout: float = DEFAULT_TIMEOUT

    def client_config(self) -> ClientConfig:
        return ClientConfig(
            url=self.url,
            headers=(
                ("X-Memory-Group", self.group),
                ("X-Memory-Cwd", self.cwd),
                ("X-Memory-Actor", self.actor),
            ),
            timeout=self.timeout,
        )


def _fallback_tools() -> list[Tool]:
    return [Tool.model_validate(schema) for schema in FALLBACK_TOOLS]


def build_server(
    config: ShimConfig,
    *,
    list_tools_fn: ListToolsFn = client.list_tools,
    call_tool_fn: CallToolFn = client.call_tool,
    list_prompts_fn: ListPromptsFn = client.list_prompts,
) -> Server:
    server: Server = Server("memory-mcp-shim")
    upstream = config.client_config()

    @server.list_tools()
    async def handle_list_tools() -> list[Tool]:
        try:
            return await list_tools_fn(upstream)
        except Exception as exc:  # an unreachable or broken upstream must not kill startup
            print(f"memory-mcp-shim: tools/list upstream unavailable: {exc}", file=sys.stderr)
            return _fallback_tools()

    @server.call_tool()
    async def handle_call_tool(name: str, arguments: dict[str, Any]) -> CallToolResult:
        try:
            result = await call_tool_fn(upstream, name, arguments or {})
        except UpstreamError as exc:
            return CallToolResult(
                content=[TextContent(type="text", text=f"memory server unreachable: {exc}")],
                isError=True,
            )
        except Exception as exc:
            return CallToolResult(
                content=[TextContent(type="text", text=f"memory tool failed: {type(exc).__name__}: {exc}")],
                isError=True,
            )
        return CallToolResult(
            content=[TextContent(type="text", text=result.text or "")],
            isError=result.is_error,
        )

    @server.list_prompts()
    async def handle_list_prompts() -> list[Prompt]:
        try:
            return await list_prompts_fn(upstream)
        except Exception:
            return []

    return server


async def _serve(server: Server) -> None:
    async with stdio_server() as (read_stream, write_stream):
        await server.run(read_stream, write_stream, server.create_initialization_options())


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="memory-mcp-shim", add_help=False)
    parser.add_argument("--cwd", default=None)
    args, _unknown = parser.parse_known_args(argv)

    try:
        cwd = args.cwd or os.getcwd()
    except OSError as exc:
        print(f"memory-mcp-shim: cannot read the working directory: {exc}", file=sys.stderr)
        return 2
    try:
        context = derive_group(cwd)
    except GroupRefused as exc:
        print(f"memory-mcp-shim: {exc}", file=sys.stderr)
        return 2

    config = ShimConfig(
        group=context.group,
        cwd=context.cwd,
        url=os.environ.get("MEMORY_MCP_URL", DEFAULT_URL),
        timeout=float(os.environ.get("MEMORY_TIMEOUT", str(DEFAULT_TIMEOUT))),
    )
    server = build_server(config)
    anyio.run(_serve, server)
    return 0
