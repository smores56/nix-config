"""`memory` CLI: write, search, promote, status, and tombstone.

Uses the same headers as the shim, so it works on a client through the loopback
forward and on smortress directly. `--group` is an explicit override and is
validated with the same work refusal as the header path.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys

from .client import ClientConfig, ToolResult, UpstreamError, call_tool
from .groups import GroupRefused, WorkRefused, derive_group, validate_group

DEFAULT_URL = "http://127.0.0.1:8182/mcp"
DEFAULT_TIMEOUT = 75.0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="memory", description="Project-scoped cross-machine memory")
    parser.add_argument("--group", help="Override the cwd-derived group (work groups are refused)")
    parser.add_argument("--cwd", help="Directory used to derive the group (default: the real cwd)")
    parser.add_argument("--url", default=os.environ.get("MEMORY_MCP_URL", DEFAULT_URL))
    parser.add_argument("--json", action="store_true", help="Emit one JSON object")
    sub = parser.add_subparsers(dest="command", required=True)

    write = sub.add_parser("write", help="Store a memory; content defaults to stdin")
    write.add_argument("content", nargs="?", help="Memory text, or - for stdin")

    search = sub.add_parser("search", help="Semantic search in this project and global memory")
    search.add_argument("query")
    search.add_argument("--limit", type=int, default=5)

    promote = sub.add_parser("promote", help="Copy an episode to the global group")
    promote.add_argument("ref", help="Episode uuid, content hash (or prefix), or name")
    promote.add_argument("--to", default="global")

    sub.add_parser("status", help="Show group, index counts, and readiness")

    tombstone = sub.add_parser("tombstone", help="Mark an episode superseded without deleting it")
    tombstone.add_argument("ref")
    tombstone.add_argument("--reason", default="")

    return parser


def resolve_context(args: argparse.Namespace) -> tuple[str, str]:
    cwd = os.path.abspath(args.cwd or os.getcwd())
    if args.group:
        return validate_group(args.group), cwd
    context = derive_group(cwd)
    return context.group, context.cwd


def _read_content(raw: str | None) -> str:
    if raw is None:
        if sys.stdin.isatty():
            raise ValueError("no content given: pass it as an argument or pipe it on stdin")
        return sys.stdin.read()
    if raw == "-":
        return sys.stdin.read()
    return raw


async def _invoke(args: argparse.Namespace, group: str, cwd: str) -> tuple[str, ToolResult]:
    tool = f"memory_{args.command}"
    arguments: dict[str, object]
    if args.command == "write":
        arguments = {"content": _read_content(args.content)}
    elif args.command == "search":
        arguments = {"query": args.query, "limit": args.limit}
    elif args.command == "promote":
        arguments = {"ref": args.ref, "to": args.to}
    elif args.command == "tombstone":
        arguments = {"ref": args.ref, "reason": args.reason}
    else:
        arguments = {}

    config = ClientConfig(
        url=args.url,
        headers=(
            ("X-Memory-Group", group),
            ("X-Memory-Cwd", cwd),
            ("X-Memory-Actor", "cli"),
        ),
        timeout=float(os.environ.get("MEMORY_TIMEOUT", str(DEFAULT_TIMEOUT))),
    )
    result = await call_tool(config, tool, arguments)
    return tool, result


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        group, cwd = resolve_context(args)
    except WorkRefused as exc:
        print(f"memory: {exc}", file=sys.stderr)
        return 2
    except GroupRefused as exc:
        print(f"memory: {exc}", file=sys.stderr)
        return 2

    try:
        tool, result = asyncio.run(_invoke(args, group, cwd))
    except UpstreamError as exc:
        print(f"memory: server unreachable at {args.url}: {exc}", file=sys.stderr)
        return 1
    except ValueError as exc:
        print(f"memory: {exc}", file=sys.stderr)
        return 1

    text = result.text
    if args.json:
        payload: dict[str, object] = {
            "tool": tool,
            "group": group,
            "ok": not result.is_error,
            "text": text,
        }
        if result.structured:
            payload["structured"] = result.structured
        print(json.dumps(payload, indent=2))
    else:
        print(text)
    return 1 if result.is_error else 0
