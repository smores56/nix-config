"""`memory` CLI: write, search, get, retry, promote, reindex, status, tombstone, export, restore.

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
from .export import (
    ExportError,
    ExportInvalid,
    GraphSnapshotError,
    add_export_parser,
    add_restore_parser,
)
from .export import dispatch as export_dispatch
from .groups import GroupRefused, derive_group, local_machine, validate_group
from .mcp_auth import TokenMissingError, authorization

DEFAULT_URL = "http://127.0.0.1:8182/mcp"
DEFAULT_TIMEOUT = 75.0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="memory", description="Attributed cross-project memory")
    parser.add_argument("--group", help="Override the cwd-derived group (work groups are refused)")
    parser.add_argument("--cwd", help="Directory used to derive the group (default: the real cwd)")
    parser.add_argument("--url", default=os.environ.get("MEMORY_MCP_URL", DEFAULT_URL))
    parser.add_argument("--json", action="store_true", help="Emit one JSON object")
    sub = parser.add_subparsers(dest="command", required=True)

    write = sub.add_parser("write", help="Store a memory; content defaults to stdin")
    write.add_argument("content", nargs="?", help="Memory text, or - for stdin")

    search = sub.add_parser("search", help="Semantic search across every allowed project")
    search.add_argument("query")
    search.add_argument("--limit", type=int, default=5)
    search.add_argument(
        "--project", default="", help="Only this project group (default: every allowed group)"
    )

    get = sub.add_parser("get", help="Show one full episode by exact reference")
    get.add_argument("ref", help="Registry uuid, hash prefix (>=12), or origin:origin_ref")

    retry = sub.add_parser("retry", help="Reset a failed episode's attempts and resubmit it")
    retry.add_argument("ref")

    promote = sub.add_parser("promote", help="Copy an episode to the global group")
    promote.add_argument("ref", help="Registry uuid, hash prefix (>=12), or origin:origin_ref")
    promote.add_argument("--to", default="global")

    reindex = sub.add_parser(
        "reindex", help="Requeue active episodes the graph no longer holds (operator)"
    )
    reindex.add_argument("--all", action="store_true", help="Every group, not just this project's")
    reindex.add_argument("--dry-run", action="store_true", help="Report without writing")
    reindex.add_argument(
        "--force",
        action="store_true",
        help="Requeue even when a group looks almost entirely missing",
    )
    reindex.add_argument(
        "--limit", type=int, default=200, help="Most rows to requeue in this call (default 200)"
    )

    sub.add_parser("status", help="Show group, registry counts, and readiness")

    tombstone = sub.add_parser("tombstone", help="Invalidate the edges an episode supports")
    tombstone.add_argument("ref")
    tombstone.add_argument("--reason", default="")

    # Export and restore work on the local registry and graph volume: they take
    # no group and never call the wrapper.
    add_export_parser(sub)
    add_restore_parser(sub)

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
        arguments = {"query": args.query, "limit": args.limit, "project": args.project}
    elif args.command in ("get", "retry"):
        arguments = {"ref": args.ref}
    elif args.command == "promote":
        arguments = {"ref": args.ref, "to": args.to}
    elif args.command == "tombstone":
        arguments = {"ref": args.ref, "reason": args.reason}
    elif args.command == "reindex":
        arguments = {
            "everywhere": args.all,
            "dry_run": args.dry_run,
            "force": args.force,
            "limit": args.limit,
        }
    else:
        arguments = {}

    config = ClientConfig(
        url=args.url,
        headers=(
            ("X-Memory-Group", group),
            ("X-Memory-Cwd", cwd),
            ("X-Memory-Actor", "cli"),
            ("X-Memory-Machine", local_machine()),
            authorization(),
        ),
        timeout=float(os.environ.get("MEMORY_TIMEOUT", str(DEFAULT_TIMEOUT))),
    )
    result = await call_tool(config, tool, arguments)
    return tool, result


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.command in ("export", "restore"):
        try:
            return export_dispatch(args)
        except (ExportError, ExportInvalid, GraphSnapshotError) as exc:
            print(f"memory: {exc}", file=sys.stderr)
            return 1
    if args.command == "reindex" and args.all and args.group:
        print(
            "memory: --group and --all are exclusive; --all already covers every group",
            file=sys.stderr,
        )
        return 2
    try:
        group, cwd = resolve_context(args)
    except GroupRefused as exc:
        print(f"memory: {exc}", file=sys.stderr)
        return 2

    try:
        tool, result = asyncio.run(_invoke(args, group, cwd))
    except TokenMissingError as exc:
        print(f"memory: {exc}", file=sys.stderr)
        return 1
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
