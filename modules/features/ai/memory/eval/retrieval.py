"""Retrieval-quality and project-boundary evaluation for the memory stack.

`search-metrics` compares the graph-backed `memory` CLI against a plain FTS5
index over the registry snapshot (the episode store is the system of record,
so it is the honest lexical baseline). `leak-check` asserts that a query issued
in one project never surfaces another project's content.

Definitions used throughout:

* an *entry* is one `[n] node` or `[n] fact` block (head line, body, optional
  provenance line); its text is every line of the block;
* a query *hits* when an entry's text contains `gold`, case-insensitively;
* a hit's *rank* is the 1-based position of the first matching entry, and
  `None` when the block contains no match.

The CLI clamps `--limit` per result type (up to `--limit` nodes and `--limit`
facts, alternated by rank in one list), so a block can be longer than `--limit`. Recall@k counts a hit only within the first
`k` entries, while MRR uses the first hit anywhere in the block; `hit_any`
exposes the gap so a fact-only answer is not silently reported as a total miss.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sqlite3
import statistics
import subprocess
import sys
import tempfile
import time
from contextlib import closing
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Sequence

DEFAULT_REGISTRY = Path(os.environ.get("MEMORY_STATE_DIR", "/var/lib/memory")) / "registry.sqlite"
DEFAULT_LIMIT = 5
DEFAULT_QUERIES = Path(__file__).with_name("queries.json")
DEFAULT_LEAK_QUERIES = Path(__file__).with_name("leak-queries.json")
CLI_TIMEOUT_S = 120.0
GLOBAL_GROUP = "global"
CATEGORIES = ("semantic", "entity", "temporal", "exact")

ENTRY_HEAD = re.compile(r"^\[(\d+)\] (node|fact)\b")
GROUP_FIELD = re.compile(r"(?:^|\|)\s*group=([^\s|,;]+)")
WORD = re.compile(r"[0-9A-Za-z_][0-9A-Za-z_.:/+#-]*")


@dataclass(frozen=True)
class BlockEntry:
    """One parsed result block: the group it carries and all of its text."""

    index: int
    kind: str
    group: str
    text: str


@dataclass(frozen=True)
class QueryResult:
    query: str
    group: str
    category: str
    gold: str
    rank: int | None
    latency_ms: float


@dataclass(frozen=True)
class Metrics:
    queries: int
    recall_at_k: float
    mrr: float
    mean_latency_ms: float
    no_hit: int
    hit_any: int


@dataclass(frozen=True)
class SystemReport:
    name: str
    overall: Metrics
    per_category: dict[str, Metrics]


@dataclass(frozen=True)
class SearchReport:
    limit: int
    systems: tuple[SystemReport, ...]
    results: dict[str, tuple[QueryResult, ...]]


@dataclass(frozen=True)
class LeakFinding:
    query: str
    issued_in: str
    foreign_group: str
    leaked_group: str
    line: str


@dataclass(frozen=True)
class LeakReport:
    queries: int
    findings: tuple[LeakFinding, ...]
    errors: tuple[str, ...]


def parse_block(text: str) -> tuple[BlockEntry, ...]:
    """Split a formatted search block into node/fact entries.

    Only head lines (`[n] node …` / `[n] fact …`) open an entry; the group is
    read from that head line because fact bodies and provenance tags never
    carry a different project id.
    """
    entries: list[BlockEntry] = []
    current: list[str] = []
    head: tuple[int, str, str] | None = None

    def flush() -> None:
        if head is not None and current:
            entries.append(BlockEntry(head[0], head[1], head[2], "\n".join(current)))

    for line in text.splitlines():
        match = ENTRY_HEAD.match(line)
        if match:
            flush()
            group = GROUP_FIELD.search(line)
            head = (int(match.group(1)), match.group(2), group.group(1) if group else "?")
            current = [line]
            continue
        if head is not None:
            current.append(line)
    flush()
    return tuple(entries)


def contains_gold(text: str, gold: str) -> bool:
    return gold.casefold() in text.casefold()


def first_hit_rank(entries: Sequence[BlockEntry], gold: str) -> int | None:
    """1-based rank of the first entry whose text contains `gold`, else None."""
    for position, entry in enumerate(entries, start=1):
        if contains_gold(entry.text, gold):
            return position
    return None


def summarize(results: Sequence[QueryResult], k: int) -> Metrics:
    """Recall@k and MRR over all queries; a miss contributes zero to both."""
    if not results:
        return Metrics(0, 0.0, 0.0, 0.0, 0, 0)
    hits = [result.rank for result in results if result.rank is not None]
    recall = sum(1 for rank in hits if rank <= k) / len(results)
    mrr = sum(1.0 / rank for rank in hits) / len(results)
    return Metrics(
        queries=len(results),
        recall_at_k=recall,
        mrr=mrr,
        mean_latency_ms=statistics.fmean(result.latency_ms for result in results),
        no_hit=len(results) - len(hits),
        hit_any=len(hits),
    )


def by_category(results: Sequence[QueryResult]) -> dict[str, tuple[QueryResult, ...]]:
    grouped: dict[str, list[QueryResult]] = {}
    for result in results:
        grouped.setdefault(result.category, []).append(result)
    return {category: tuple(grouped[category]) for category in CATEGORIES if category in grouped}


def fts_query(text: str) -> str | None:
    """OR-join quoted terms so a phrase query is never treated as an AND.

    Terms are quoted because raw punctuation (`--files-from0`, paths) would
    otherwise be FTS5 syntax; a query with no usable term returns None.
    """
    terms = [word for word in WORD.findall(text) if len(word) > 1]
    if not terms:
        return None
    return " OR ".join(f'"{term}"' for term in terms)


def _snapshot_rows(registry: Path, group: str) -> list[str]:
    """Row contents for `group` plus global, from the live database or a copy.

    A live FalkorDB-side registry is WAL-mode: opening it read-only tries to
    create the shared-memory file and fails with "attempt to write a readonly
    database". Falling back to a copy of the database and its sidecars keeps
    the harness usable against the running service without a manual step.
    """
    query = (
        "SELECT content FROM episodes WHERE group_id IN (?, ?) "
        "ORDER BY created_at, content_hash"
    )
    try:
        with closing(sqlite3.connect(f"file:{registry}?mode=ro", uri=True)) as snapshot:
            return [row[0] for row in snapshot.execute(query, (group, GLOBAL_GROUP))]
    except sqlite3.OperationalError:
        staging = Path(tempfile.mkdtemp(prefix="memory-eval-"))
        for name in (registry.name, f"{registry.name}-wal", f"{registry.name}-shm"):
            source = registry.with_name(name)
            if source.exists():
                shutil.copyfile(source, staging / name)
        with closing(sqlite3.connect(staging / registry.name)) as snapshot:
            return [row[0] for row in snapshot.execute(query, (group, GLOBAL_GROUP))]


def build_fts(registry: Path, group: str) -> sqlite3.Connection:
    """In-memory FTS5 index of the snapshot rows for `group` plus global."""
    connection = sqlite3.connect(":memory:")
    connection.execute("CREATE VIRTUAL TABLE episodes_fts USING fts5(content)")
    connection.executemany(
        "INSERT INTO episodes_fts (content) VALUES (?)",
        ((content,) for content in _snapshot_rows(registry, group)),
    )
    connection.commit()
    return connection


def fts_search(connection: sqlite3.Connection, query: str, limit: int) -> list[str]:
    match = fts_query(query)
    if match is None:
        return []
    rows = connection.execute(
        "SELECT content FROM episodes_fts WHERE episodes_fts MATCH ? "
        "ORDER BY bm25(episodes_fts) LIMIT ?",
        (match, limit),
    )
    return [row[0] for row in rows]


def cli_command(group: str, query: str, limit: int) -> list[str]:
    # `--group` is a global option: argparse only accepts it before the
    # subcommand, unlike the `memory search --group` form in older docs.
    return ["memory", "--json", "--group", group, "search", "--limit", str(limit), query]


def run_cli(group: str, query: str, limit: int) -> tuple[str | None, float]:
    """Run one live search; return its text block and wall time in ms."""
    started = time.monotonic()
    try:
        completed = subprocess.run(
            cli_command(group, query, limit),
            capture_output=True,
            text=True,
            timeout=CLI_TIMEOUT_S,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        print(f"memory search failed for {query!r}: {error}", file=sys.stderr)
        return None, (time.monotonic() - started) * 1000.0
    elapsed_ms = (time.monotonic() - started) * 1000.0
    if completed.returncode != 0:
        print(
            f"memory search exited {completed.returncode} for {query!r}: {completed.stderr.strip()}",
            file=sys.stderr,
        )
        return None, elapsed_ms
    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError:
        print(f"memory search returned non-JSON for {query!r}", file=sys.stderr)
        return None, elapsed_ms
    if not payload.get("ok", False):
        print(f"memory search reported failure for {query!r}: {payload}", file=sys.stderr)
    text = payload.get("text")
    return (text if isinstance(text, str) else None), elapsed_ms


def rank_in_block(text: str | None, gold: str) -> int | None:
    """Rank of `gold` in a formatted block; None when the block is unusable."""
    if text is None:
        return None
    return first_hit_rank(parse_block(text), gold)


def load_json(path: Path) -> list[dict[str, object]]:
    return json.loads(path.read_text())


def select_queries(entries: Iterable[dict[str, object]], only: str | None) -> list[dict[str, object]]:
    return [entry for entry in entries if only is None or entry["category"] == only]


def cli_results(
    queries: Sequence[dict[str, object]], limit: int
) -> tuple[QueryResult, ...]:
    results: list[QueryResult] = []
    for entry in queries:
        text, latency_ms = run_cli(str(entry["group"]), str(entry["query"]), limit)
        results.append(
            QueryResult(
                query=str(entry["query"]),
                group=str(entry["group"]),
                category=str(entry["category"]),
                gold=str(entry["gold"]),
                rank=rank_in_block(text, str(entry["gold"])),
                latency_ms=latency_ms,
            )
        )
    return tuple(results)


def fts_results(
    queries: Sequence[dict[str, object]], registry: Path, limit: int
) -> tuple[QueryResult, ...]:
    results: list[QueryResult] = []
    indexes: dict[str, sqlite3.Connection] = {}
    for entry in queries:
        group = str(entry["group"])
        if group not in indexes:
            indexes[group] = build_fts(registry, group)
        started = time.monotonic()
        rows = fts_search(indexes[group], str(entry["query"]), limit)
        elapsed_ms = (time.monotonic() - started) * 1000.0
        gold = str(entry["gold"])
        rank = next(
            (position for position, content in enumerate(rows, start=1) if contains_gold(content, gold)),
            None,
        )
        results.append(
            QueryResult(
                query=str(entry["query"]),
                group=group,
                category=str(entry["category"]),
                gold=gold,
                rank=rank,
                latency_ms=elapsed_ms,
            )
        )
    return tuple(results)


def system_report(name: str, results: Sequence[QueryResult], limit: int) -> SystemReport:
    return SystemReport(
        name=name,
        overall=summarize(results, limit),
        per_category={category: summarize(items, limit) for category, items in by_category(results).items()},
    )


def leak_findings(text: str | None, issued_in: str) -> tuple[BlockEntry, ...]:
    """Entries whose head line names a group other than the project or global."""
    if text is None:
        return ()
    allowed = {issued_in, GLOBAL_GROUP}
    return tuple(entry for entry in parse_block(text) if entry.group not in allowed)


def check_leaks(
    queries: Sequence[dict[str, object]], limit: int
) -> LeakReport:
    findings: list[LeakFinding] = []
    errors: list[str] = []
    for entry in queries:
        query = str(entry["query"])
        issued_in = str(entry["group"])
        text, _ = run_cli(issued_in, query, limit)
        if text is None:
            errors.append(query)
            continue
        for leaked in leak_findings(text, issued_in):
            findings.append(
                LeakFinding(
                    query=query,
                    issued_in=issued_in,
                    foreign_group=str(entry["foreign_group"]),
                    leaked_group=leaked.group,
                    line=leaked.text.splitlines()[0],
                )
            )
    return LeakReport(queries=len(queries), findings=tuple(findings), errors=tuple(errors))


def format_metrics(metrics: Metrics) -> str:
    return (
        f"{metrics.recall_at_k:>8.3f} {metrics.mrr:>6.3f} "
        f"{metrics.mean_latency_ms:>9.1f} {metrics.no_hit:>6d} {metrics.hit_any:>6d}"
    )


def format_search_table(report: SearchReport) -> str:
    header = (
        f"{'system':<16}{'recall@' + str(report.limit):>9} {'mrr':>6} "
        f"{'mean ms':>9} {'miss':>6} {'any':>6}"
    )
    lines = [header]
    for system in report.systems:
        lines.append(f"{system.name:<16}{format_metrics(system.overall)}")
    for system in report.systems:
        if not system.per_category:
            continue
        lines.append("")
        lines.append(f"{system.name} by category")
        for category, metrics in system.per_category.items():
            lines.append(f"  {category:<14}{format_metrics(metrics)}")
    return "\n".join(lines)


def search_payload(report: SearchReport) -> dict[str, object]:
    def metrics_payload(metrics: Metrics) -> dict[str, object]:
        return {
            "queries": metrics.queries,
            "recall_at_k": metrics.recall_at_k,
            "mrr": metrics.mrr,
            "mean_latency_ms": metrics.mean_latency_ms,
            "no_hit": metrics.no_hit,
            "hit_any": metrics.hit_any,
        }

    return {
        "limit": report.limit,
        "systems": {
            system.name: {
                "overall": metrics_payload(system.overall),
                "per_category": {
                    category: metrics_payload(metrics)
                    for category, metrics in system.per_category.items()
                },
            }
            for system in report.systems
        },
        "results": {
            name: [
                {
                    "query": result.query,
                    "group": result.group,
                    "category": result.category,
                    "gold": result.gold,
                    "rank": result.rank,
                    "latency_ms": result.latency_ms,
                }
                for result in results
            ]
            for name, results in report.results.items()
        },
    }


def leak_payload(report: LeakReport) -> dict[str, object]:
    return {
        "queries": report.queries,
        "leaks": [
            {
                "query": finding.query,
                "issued_in": finding.issued_in,
                "foreign_group": finding.foreign_group,
                "leaked_group": finding.leaked_group,
                "line": finding.line,
            }
            for finding in report.findings
        ],
        "errors": list(report.errors),
        "summary": {
            "leaks": len(report.findings),
            "errors": len(report.errors),
        },
    }


def format_leak_table(report: LeakReport) -> str:
    lines = [f"queries: {report.queries}  leaks: {len(report.findings)}  errors: {len(report.errors)}"]
    for finding in report.findings:
        lines.append(
            f"LEAK {finding.issued_in} -> {finding.leaked_group} "
            f"(tempted by {finding.foreign_group}): {finding.query}"
        )
        lines.append(f"  {finding.line}")
    for query in report.errors:
        lines.append(f"ERROR no result for: {query}")
    return "\n".join(lines)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--registry", type=Path, default=DEFAULT_REGISTRY)
    parser.add_argument("--limit", type=int, default=DEFAULT_LIMIT)
    parser.add_argument("--only", choices=CATEGORIES, help="labelled queries of one category")
    parser.add_argument("--json", action="store_true", help="emit one JSON object")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("search-metrics", help="recall@k and MRR for the CLI and an FTS5 baseline")
    commands.add_parser("leak-check", help="fail on any entry from a foreign project group")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.command == "search-metrics":
        queries = select_queries(load_json(DEFAULT_QUERIES), args.only)
        live = cli_results(queries, args.limit)
        lexical = fts_results(queries, args.registry, args.limit)
        report = SearchReport(
            limit=args.limit,
            systems=(
                system_report("cli (memory)", live, args.limit),
                system_report("fts5 baseline", lexical, args.limit),
            ),
            results={"cli": live, "fts5": lexical},
        )
        print(json.dumps(search_payload(report), indent=2) if args.json else format_search_table(report))
        return 0

    report = check_leaks(load_json(DEFAULT_LEAK_QUERIES), args.limit)
    print(json.dumps(leak_payload(report), indent=2) if args.json else format_leak_table(report))
    return 0 if not report.findings and not report.errors else 1


if __name__ == "__main__":
    raise SystemExit(main())
