"""`memory` CLI: write, search, promote, status, tombstone, and ingest.

Uses the same headers as the shim, so it works on a client through the loopback
forward and on smortress directly. `--group` is an explicit override and is
validated with the same work refusal as the header path. `ingest` runs only
where raw Graphiti is reachable (smortress) and sets the group per episode.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys

from .client import ClientConfig, ToolResult, UpstreamError, call_tool
from .groups import GroupRefused, derive_group, validate_group

DEFAULT_URL = "http://127.0.0.1:8182/mcp"
DEFAULT_TIMEOUT = 75.0
DEFAULT_NOTES_DIR = "~/Documents"
DEFAULT_GRAPHITI_URL = "http://127.0.0.1:8184/mcp"
DEFAULT_REDIS_URL = "redis://127.0.0.1:6379"


def default_docs_root() -> str:
    """`~/code/github.com/<owner>`, with the owner from the shared setting."""
    from .ingest_sources import personal_owner

    return f"~/code/github.com/{personal_owner()}"


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

    ingest = sub.add_parser("ingest", help="Bulk-ingest sdlc issues, personal notes, and repo docs")
    ingest.add_argument("source", choices=["sdlc", "notes", "docs", "all"])
    ingest.add_argument("--limit", type=int, help="Maximum episodes per source")
    ingest.add_argument("--dry-run", action="store_true", help="Print the episode plan; write nothing")
    ingest.add_argument("--report", help="Report path (default ~/.local/state/memory/ingest-<timestamp>.json)")
    ingest.add_argument("--batch", type=int, default=1, help="Episodes written before verification (default 1)")
    ingest.add_argument(
        "--timeout", type=float, default=600.0, help="Grace per batch before an episode is absent (seconds)"
    )
    ingest.add_argument(
        "--repair",
        action="store_true",
        help="Rewrite a previously attempted episode once, after an exact absence check",
    )
    ingest.add_argument(
        "--reset-state",
        action="store_true",
        help="Archive the state file and treat this as a first run (requires --force)",
    )
    ingest.add_argument(
        "--force",
        action="store_true",
        help="Acknowledge the destructive --reset-state; a reset re-attempts every planned episode",
    )
    ingest.add_argument("--notes-dir", default=DEFAULT_NOTES_DIR)
    ingest.add_argument("--docs-root", default=None, help="Clone root (default ~/code/github.com/<owner>)")
    ingest.add_argument("--repo-list", help="File of repo names for docs ingestion, one per line")
    ingest.add_argument("--repo", action="append", default=[], help="Restrict docs to this repo (repeatable)")
    ingest.add_argument("--state", help="State path (default ~/.local/state/memory/ingest-state.json)")
    ingest.add_argument("--graphiti-url", default=os.environ.get("MEMORY_GRAPHITI_URL", DEFAULT_GRAPHITI_URL))
    ingest.add_argument(
        "--redis-url",
        default=os.environ.get("MEMORY_REDIS_URL", DEFAULT_REDIS_URL),
        help="FalkorDB URL used for exact presence checks",
    )
    ingest.add_argument("--verbose", action="store_true", help="Log every episode to stderr")

    return parser


def build_plans(args: argparse.Namespace) -> tuple[list, dict[str, str]]:
    """Build the episode plans for a source without touching the memory service.

    `all` runs each corpus independently: a failing source is reported and the
    rest still ingest. A single named source fails the command instead.
    """
    from .ingest_runner import IngestError
    from .ingest_sources import (
        SourceError,
        docs_plan,
        fetch_issues,
        notes_plan,
        repo_filter,
        sdlc_plan,
    )

    builders = {
        "sdlc": lambda: sdlc_plan(fetch_issues()),
        "notes": lambda: notes_plan(args.notes_dir),
        "docs": lambda: docs_plan(
            args.docs_root or default_docs_root(),
            repos=repo_filter(args.repo_list, args.repo),
        ),
    }
    names = list(builders) if args.source == "all" else [args.source]
    plans = []
    errors: dict[str, str] = {}
    for name in names:
        try:
            plans.append(builders[name]())
        except SourceError as exc:
            if args.source != "all":
                raise IngestError(str(exc)) from exc
            errors[name] = str(exc)
    return [plan.limited(args.limit) for plan in plans], errors


async def run_ingest(args: argparse.Namespace) -> dict[str, object]:
    from .ingest_runner import IngestRunner, RunnerConfig

    plans, source_errors = build_plans(args)
    config = RunnerConfig(
        wrapper_url=args.url,
        graphiti_url=args.graphiti_url,
        redis_url=args.redis_url,
        cwd=os.path.abspath(args.cwd or os.getcwd()),
        batch=max(1, args.batch),
        verify_timeout=args.timeout,
        dry_run=args.dry_run,
        verbose=args.verbose,
        repair=args.repair,
        force=args.force,
        reset_state=args.reset_state,
        json_output=args.json,
        report_path=args.report,
        state_path=args.state,
    )
    return await IngestRunner(config).run(plans, source_errors=source_errors)


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
    if args.command == "ingest":
        from .ingest_runner import IngestError

        # `ingest` derives a group per episode; a single override would silently
        # file the whole corpus under one group.
        if args.group:
            print(
                "memory: --group is not valid with ingest; each corpus sets the group per episode",
                file=sys.stderr,
            )
            return 2
        try:
            report = asyncio.run(run_ingest(args))
        except IngestError as exc:
            print(f"memory: {exc}", file=sys.stderr)
            return 1
        except KeyboardInterrupt:
            print("memory: ingest interrupted", file=sys.stderr)
            return 130
        if args.json:
            print(json.dumps(report, indent=2, sort_keys=True))
        return 0 if not report.get("failures") else 1

    try:
        group, cwd = resolve_context(args)
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
