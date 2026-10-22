"""`memory` CLI: write, search, get, retry, promote, status, tombstone, ingest, export, restore.

Uses the same headers as the shim, so it works on a client through the loopback
forward and on smortress directly. `--group` is an explicit override and is
validated with the same work refusal as the header path. `ingest` plans as the
user and submits through the wrapper's loopback routes, so the registry stays
the single ledger and single writer.
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
from .groups import GroupRefused, derive_group, validate_group

DEFAULT_URL = "http://127.0.0.1:8182/mcp"
DEFAULT_TIMEOUT = 75.0
DEFAULT_NOTES_DIR = "~/Documents"
DEFAULT_SESSION_SAMPLE = 50
DEFAULT_SESSION_CONCURRENCY = 3


def default_docs_root() -> str:
    """`~/code/github.com/<owner>`, with the owner from the shared setting."""
    from .ingest_sources import personal_owner

    return f"~/code/github.com/{personal_owner()}"


def internal_url(wrapper_url: str) -> str:
    """The loopback HTTP origin behind the MCP URL (`.../mcp`)."""
    return wrapper_url.rstrip("/").removesuffix("/mcp")


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

    get = sub.add_parser("get", help="Show one full episode by exact reference")
    get.add_argument("ref", help="Registry uuid, hash prefix (>=12), or origin:origin_ref")

    retry = sub.add_parser("retry", help="Reset a failed episode's attempts and resubmit it")
    retry.add_argument("ref")

    promote = sub.add_parser("promote", help="Copy an episode to the global group")
    promote.add_argument("ref", help="Registry uuid, hash prefix (>=12), or origin:origin_ref")
    promote.add_argument("--to", default="global")

    sub.add_parser("status", help="Show group, registry counts, and readiness")

    tombstone = sub.add_parser("tombstone", help="Invalidate the edges an episode supports")
    tombstone.add_argument("ref")
    tombstone.add_argument("--reason", default="")

    ingest = sub.add_parser("ingest", help="Bulk-ingest sdlc issues, personal notes, repo docs, and Maki sessions")
    ingest.add_argument("source", choices=["sdlc", "notes", "docs", "sessions", "all"])
    ingest.add_argument("--limit", type=int, help="Maximum episodes per source (not sessions)")
    ingest.add_argument("--dry-run", action="store_true", help="Print the episode plan; write nothing")
    ingest.add_argument("--report", help="Report path (default ~/.local/state/memory/ingest-<timestamp>.json)")
    ingest.add_argument("--concurrency", type=int, default=4, help="Concurrent submissions (default 4)")
    ingest.add_argument("--timeout", type=float, default=60.0, help="Per-request timeout (seconds)")
    ingest.add_argument("--notes-dir", default=DEFAULT_NOTES_DIR)
    ingest.add_argument("--docs-root", default=None, help="Clone root (default ~/code/github.com/<owner>)")
    ingest.add_argument("--repo-list", help="File of repo names for docs ingestion, one per line")
    ingest.add_argument("--repo", action="append", default=[], help="Restrict docs to this repo (repeatable)")
    ingest.add_argument(
        "--sessions-dir",
        default=None,
        help="Maki sessions directory (default: $MAKI_SESSIONS_DIR, then the XDG state/data dirs)",
    )
    ingest.add_argument(
        "--session-limit",
        type=int,
        default=DEFAULT_SESSION_SAMPLE,
        help=f"Most recent sessions to sample (default {DEFAULT_SESSION_SAMPLE}; `all` uses this too)",
    )
    ingest.add_argument(
        "--session-concurrency",
        type=int,
        default=DEFAULT_SESSION_CONCURRENCY,
        help=f"Concurrent summaries (default {DEFAULT_SESSION_CONCURRENCY})",
    )
    ingest.add_argument("--verbose", action="store_true", help="Log every skipped episode to stderr")

    # Export and restore work on the local registry and graph volume: they take
    # no group and never call the wrapper.
    add_export_parser(sub)
    add_restore_parser(sub)

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
    names = [name for name in builders if args.source in ("all", name)]
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


async def build_sessions(args: argparse.Namespace) -> "SessionPlanResult":
    """Parse and (unless dry-run) summarize the sampled sessions.

    A dry run never constructs the summary client, so it cannot reach the model
    or the gateway.
    """
    from .sessions import SessionPlanResult, build_session_plan
    from .session_summary import SummaryClient

    if args.dry_run:
        return await build_session_plan(
            sessions_dir=args.sessions_dir,
            limit=args.session_limit,
            dry_run=True,
            concurrency=args.session_concurrency,
        )
    async with SummaryClient() as client:
        result: SessionPlanResult = await build_session_plan(
            sessions_dir=args.sessions_dir,
            limit=args.session_limit,
            summarizer=client.summarize,
            concurrency=args.session_concurrency,
        )
    return result


async def run_ingest(args: argparse.Namespace) -> dict[str, object]:
    from .ingest_runner import IngestError, IngestRunner, RunnerConfig
    from .sessions import SessionError, session_observer, summary_line

    plans, source_errors = build_plans(args)
    extras: dict[str, object] = {}
    observer = None
    if args.source in ("sessions", "all"):
        try:
            built = await build_sessions(args)
        except SessionError as exc:
            if args.source != "all":
                raise IngestError(str(exc)) from exc
            source_errors["sessions"] = str(exc)
        else:
            plans.append(built.plan)
            extras["sessions"] = built.report
            observer = session_observer(built.report)
    config = RunnerConfig(
        internal_url=internal_url(args.url),
        timeout=args.timeout,
        concurrency=max(1, args.concurrency),
        dry_run=args.dry_run,
        verbose=args.verbose,
        json_output=args.json,
        report_path=args.report,
    )
    report = await IngestRunner(config).run(
        plans, source_errors=source_errors, observer=observer, extras=extras
    )
    if "sessions" in extras:
        print(f"[ingest] {summary_line(extras['sessions'])}", file=sys.stderr)
    return report


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
    elif args.command in ("get", "retry"):
        arguments = {"ref": args.ref}
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
    if args.command in ("export", "restore"):
        try:
            return export_dispatch(args)
        except (ExportError, ExportInvalid, GraphSnapshotError) as exc:
            print(f"memory: {exc}", file=sys.stderr)
            return 1
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
