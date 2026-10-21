"""Batch ingest runner: write through the wrapper, verify in raw Graphiti, repair.

Graphiti extracts asynchronously and can drop an episode from its in-memory
queue, so a queued write is not a stored episode. The runner keeps batches
small, polls `get_episodes` until every uuid5 identity appears, and repairs a
miss exactly once by tombstoning the index row and rewriting the content.
"""

from __future__ import annotations

import asyncio
import json
import os
import re
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

from .client import ClientConfig, ToolResult, UpstreamError, call_tool
from .graphiti import BackendError, GraphitiBackend
from .ingest_sources import Episode, Plan
from .normalize import content_hash, episode_uuid, normalize_content
from .store import utcnow

DEFAULT_WRAPPER_URL = "http://127.0.0.1:8182/mcp"
DEFAULT_GRAPHITI_URL = "http://127.0.0.1:8184/mcp"
DEFAULT_BATCH = 3
DEFAULT_VERIFY_TIMEOUT = 300.0
DEFAULT_POLL_SECONDS = 5.0
DEFAULT_WRITE_TIMEOUT = 90.0
MAX_FETCH = 5000
REPAIR_REASON = "ingest repair: queued write never appeared in the graph"
RECONCILE_REASON = "ingest reconcile: planned episode was never stored in the graph"

COUNTERS = ("built", "queued", "duplicate", "skipped", "reconciled", "verified", "repaired", "failed")

_ID_TOKEN = re.compile(r"(?:^|;\s*)id=([0-9a-fA-F-]{36})")
_HASH_TOKEN = re.compile(r"(?:^|;\s*)hash=([0-9a-f]{64})")


def _provenance(description: str) -> dict[str, str]:
    tokens: dict[str, str] = {}
    for part in description.split("; "):
        key, separator, value = part.partition("=")
        if separator and key.strip():
            tokens.setdefault(key.strip(), value.strip())
    return tokens


class IngestError(RuntimeError):
    """The ingest cannot run here or a source is unreadable."""


def default_state_dir() -> Path:
    base = os.environ.get("XDG_STATE_HOME", "").strip()
    return (Path(base) if base else Path.home() / ".local" / "state") / "memory"


def _stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def _atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(text, encoding="utf-8")
    temporary.replace(path)


@dataclass(frozen=True)
class RunnerConfig:
    wrapper_url: str = DEFAULT_WRAPPER_URL
    graphiti_url: str = DEFAULT_GRAPHITI_URL
    cwd: str = field(default_factory=os.getcwd)
    batch: int = DEFAULT_BATCH
    verify_timeout: float = DEFAULT_VERIFY_TIMEOUT
    poll_seconds: float = DEFAULT_POLL_SECONDS
    write_timeout: float = DEFAULT_WRITE_TIMEOUT
    dry_run: bool = False
    verbose: bool = False
    report_path: str | None = None
    state_path: str | None = None

    @property
    def resolved_report_path(self) -> Path:
        return Path(self.report_path).expanduser() if self.report_path else default_state_dir() / f"ingest-{_stamp()}.json"

    @property
    def resolved_state_path(self) -> Path:
        return Path(self.state_path).expanduser() if self.state_path else default_state_dir() / "ingest-state.json"


@dataclass(frozen=True)
class BatchEntry:
    episode: Episode
    digest: str
    uuid: str
    content: str


class IngestState:
    """Verified `(source, source_id)` entries, so a re-run skips work already proven."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self.entries: dict[str, dict[str, str]] = {}
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            payload = {}
        verified = payload.get("verified") if isinstance(payload, dict) else None
        if isinstance(verified, dict):
            self.entries = {
                str(key): value for key, value in verified.items() if isinstance(value, dict)
            }

    @staticmethod
    def key(source: str, source_id: str) -> str:
        return f"{source}\t{source_id}"

    def is_verified(self, source: str, source_id: str, digest: str) -> bool:
        entry = self.entries.get(self.key(source, source_id))
        return entry is not None and entry.get("hash") == digest

    def mark(self, *, source: str, source_id: str, group: str, digest: str, uid: str) -> None:
        self.entries[self.key(source, source_id)] = {
            "group": group,
            "hash": digest,
            "uuid": uid,
            "verified_at": utcnow(),
        }

    def save(self) -> None:
        _atomic_write(self.path, json.dumps({"version": 1, "verified": self.entries}, indent=2, sort_keys=True) + "\n")


class Report:
    def __init__(self) -> None:
        self.sources: dict[str, dict[str, dict[str, int]]] = {}
        self.failures: list[dict[str, str]] = []

    def bump(self, source: str, group: str, counter: str, amount: int = 1) -> None:
        bucket = self.sources.setdefault(source, {}).setdefault(group, {name: 0 for name in COUNTERS})
        bucket[counter] = bucket.get(counter, 0) + amount

    def fail(self, *, source: str, source_id: str, group: str, error: str) -> None:
        self.bump(source, group, "failed")
        self.failures.append({"source": source, "source_id": source_id, "group": group, "error": error[:300]})

    def _totals(self, groups: dict[str, dict[str, int]]) -> dict[str, int]:
        totals = {name: 0 for name in COUNTERS}
        for counts in groups.values():
            for name in COUNTERS:
                totals[name] += counts.get(name, 0)
        return totals

    def to_dict(self, *, started_at: str, elapsed: float, config: RunnerConfig) -> dict[str, object]:
        sources: dict[str, object] = {}
        overall = {name: 0 for name in COUNTERS}
        for source, groups in sorted(self.sources.items()):
            totals = self._totals(groups)
            for name in COUNTERS:
                overall[name] += totals[name]
            attempted = totals["queued"] + totals["duplicate"]
            sources[source] = {
                "totals": totals,
                "duplicate_rate": round(totals["duplicate"] / attempted, 4) if attempted else 0.0,
                "groups": dict(sorted(groups.items())),
            }
        attempted = overall["queued"] + overall["duplicate"]
        return {
            "started_at": started_at,
            "finished_at": utcnow(),
            "elapsed_seconds": round(elapsed, 1),
            "batch": config.batch,
            "verify_timeout_seconds": config.verify_timeout,
            "dry_run": config.dry_run,
            "totals": overall,
            "duplicate_rate": round(overall["duplicate"] / attempted, 4) if attempted else 0.0,
            "sources": sources,
            "failures": self.failures,
        }


def _episode_status(text: str) -> str:
    if "Duplicate memory" in text:
        return "duplicate"
    return "queued"


class IngestRunner:
    def __init__(
        self,
        config: RunnerConfig,
        *,
        backend: GraphitiBackend | None = None,
        call_tool_fn=call_tool,
        state: IngestState | None = None,
        sleep=asyncio.sleep,
        clock=time.monotonic,
    ) -> None:
        self.config = config
        self.backend = backend or GraphitiBackend(config.graphiti_url, timeout=60.0)
        self.call_tool_fn = call_tool_fn
        self.state = state or IngestState(config.resolved_state_path)
        self.sleep = sleep
        self.clock = clock
        self.report = Report()

    def _log(self, message: str) -> None:
        print(f"[ingest] {message}", file=sys.stderr)

    def _config_for(self, *, group: str, source: str = "", source_id: str = "") -> ClientConfig:
        headers = [
            ("X-Memory-Group", group),
            ("X-Memory-Cwd", self.config.cwd),
            ("X-Memory-Actor", "ingest"),
        ]
        if source:
            headers.append(("X-Memory-Source", source))
        if source_id:
            headers.append(("X-Memory-Source-ID", source_id))
        return ClientConfig(url=self.config.wrapper_url, headers=tuple(headers), timeout=self.config.write_timeout)

    async def _check_services(self) -> None:
        try:
            await self.backend.get_status()
        except BackendError as exc:
            raise IngestError(
                f"raw Graphiti is unreachable at {self.config.graphiti_url} ({exc}). "
                "Run `memory ingest` on smortress, where 127.0.0.1:8184 is reachable; "
                "the wrapper alone cannot verify or repair episodes."
            ) from exc
        try:
            result = await self.call_tool_fn(
                self._config_for(group="global", source="ingest", source_id="preflight"),
                "memory_status",
                {},
            )
        except UpstreamError as exc:
            raise IngestError(f"memory wrapper unreachable at {self.config.wrapper_url}: {exc}") from exc
        if result.is_error:
            raise IngestError(f"memory wrapper refused the preflight: {result.text.strip()[:300]}")

    async def _write(self, entry: BatchEntry) -> str:
        result: ToolResult = await self.call_tool_fn(
            self._config_for(
                group=entry.episode.group,
                source=entry.episode.source,
                source_id=entry.episode.source_id,
            ),
            "memory_write",
            {"content": entry.content},
        )
        if result.is_error:
            raise IngestError(result.text.strip() or "memory_write failed")
        return _episode_status(result.text)

    async def _tombstone(self, entry: BatchEntry, *, reason: str = REPAIR_REASON) -> None:
        result = await self.call_tool_fn(
            self._config_for(group=entry.episode.group),
            "memory_tombstone",
            {"ref": entry.uuid, "reason": reason},
        )
        if result.is_error:
            raise IngestError(result.text.strip() or "memory_tombstone failed")

    async def _fetch_episodes(self, group: str, minimum: int) -> list[dict[str, object]]:
        """Read at least `minimum` recent episodes, growing to MAX_FETCH."""
        page = max(50, minimum)
        while True:
            episodes = await self.backend.get_episodes([group], page)
            if len(episodes) < page or page >= MAX_FETCH:
                return episodes
            page = min(MAX_FETCH, page * 2)

    async def _reconcile(self, queue: list[BatchEntry]) -> None:
        """Tombstone planned rows that never reached the graph before writing.

        A queued write that Graphiti dropped leaves the wrapper index row
        `active`. A plain re-run then gets `Duplicate memory` for it and waits
        out the whole verification window before repairing. One pass over
        `get_episodes` per group finds those rows up front, so the write is a
        real queue instead of a duplicate, and the repair path stays a fallback.
        """
        by_group: dict[str, list[BatchEntry]] = {}
        for entry in queue:
            by_group.setdefault(entry.episode.group, []).append(entry)

        present_source_ids: set[tuple[str, str]] = set()
        present_ids: set[str] = set()
        present_hashes: set[str] = set()
        for group, entries in by_group.items():
            try:
                episodes = await self._fetch_episodes(group, 2 * len(entries))
            except BackendError as exc:
                # Verification still protects the run; a reconcile failure must
                # not block writes that were never attempted before.
                self._log(f"reconcile {group}: {exc}; skipping pre-verification")
                return
            for episode in episodes:
                description = str(
                    episode.get("source_description") or episode.get("sourceDescription") or ""
                )
                present_ids.update(_ID_TOKEN.findall(description))
                present_hashes.update(_HASH_TOKEN.findall(description))
                tokens = _provenance(description)
                if tokens.get("source") and tokens.get("source_id"):
                    present_source_ids.add((tokens["source"], tokens["source_id"]))

        missing = [
            entry
            for entry in queue
            if entry.uuid not in present_ids
            and entry.digest not in present_hashes
            and (entry.episode.source, entry.episode.source_id) not in present_source_ids
        ]
        if not missing:
            return
        self._log(f"reconcile: {len(missing)} planned episode(s) absent from the graph")
        for entry in missing:
            try:
                await self._tombstone(entry, reason=RECONCILE_REASON)
            except (IngestError, UpstreamError) as exc:
                # No index row means nothing to revive; the write is fresh.
                if "no stored episode" not in str(exc):
                    self._log(f"reconcile {entry.episode.source_id}: {exc}")
                continue
            self.report.bump(entry.episode.source, entry.episode.group, "reconciled")
            if self.config.verbose:
                self._log(f"reconciled {entry.episode.source} {entry.episode.source_id}")

    async def _verify(self, entries: list[BatchEntry], *, timeout: float) -> tuple[set[str], set[str]]:
        """Poll raw Graphiti until every uuid/hash appears, or the deadline passes."""
        wanted: dict[str, tuple[str, str]] = {entry.uuid: (entry.episode.group, entry.digest) for entry in entries}
        by_group: dict[str, list[tuple[str, str]]] = {}
        for uid, (group, digest) in wanted.items():
            by_group.setdefault(group, []).append((uid, digest))
        fetch = {group: max(50, 2 * len(items)) for group, items in by_group.items()}
        found: set[str] = set()
        deadline = self.clock() + timeout

        while True:
            for group, items in by_group.items():
                if all(uid in found for uid, _digest in items):
                    continue
                try:
                    episodes = await self.backend.get_episodes([group], fetch[group])
                except BackendError as exc:
                    self._log(f"verify {group}: {exc}")
                    episodes = []
                if len(episodes) >= fetch[group] and fetch[group] < MAX_FETCH:
                    fetch[group] = min(MAX_FETCH, fetch[group] * 2)
                for episode in episodes:
                    description = str(
                        episode.get("source_description") or episode.get("sourceDescription") or ""
                    )
                    ids = set(_ID_TOKEN.findall(description))
                    hashes = set(_HASH_TOKEN.findall(description))
                    for uid, digest in items:
                        if uid in ids or digest in hashes:
                            found.add(uid)
            pending = set(wanted) - found
            if not pending:
                break
            remaining = deadline - self.clock()
            if remaining <= 0:
                break
            await self.sleep(min(self.config.poll_seconds, remaining))
        return found, set(wanted) - found

    async def _process_batch(self, batch: list[BatchEntry]) -> None:
        written: list[BatchEntry] = []
        for entry in batch:
            try:
                status = await self._write(entry)
            except (IngestError, UpstreamError) as exc:
                self.report.fail(
                    source=entry.episode.source,
                    source_id=entry.episode.source_id,
                    group=entry.episode.group,
                    error=str(exc),
                )
                self._log(f"write failed {entry.episode.source_id}: {exc}")
                continue
            self.report.bump(entry.episode.source, entry.episode.group, status)
            written.append(entry)
            if self.config.verbose:
                self._log(f"{status} {entry.episode.source} {entry.episode.source_id} -> {entry.episode.group}")
        if not written:
            return

        found, missing = await self._verify(written, timeout=self.config.verify_timeout)
        for entry in written:
            if entry.uuid in found:
                self.report.bump(entry.episode.source, entry.episode.group, "verified")
                self.state.mark(
                    source=entry.episode.source,
                    source_id=entry.episode.source_id,
                    group=entry.episode.group,
                    digest=entry.digest,
                    uid=entry.uuid,
                )
        if missing:
            repaired = [entry for entry in written if entry.uuid in missing]
            self._log(f"verification missed {len(repaired)} episode(s); repairing once")
            retry: list[BatchEntry] = []
            for entry in repaired:
                try:
                    await self._tombstone(entry)
                    status = await self._write(entry)
                except (IngestError, UpstreamError) as exc:
                    self.report.fail(
                        source=entry.episode.source,
                        source_id=entry.episode.source_id,
                        group=entry.episode.group,
                        error=f"repair failed: {exc}",
                    )
                    continue
                if status != "queued":
                    self._log(f"repair rewritten as {status} for {entry.episode.source_id}")
                retry.append(entry)
            if retry:
                found_after, still_missing = await self._verify(retry, timeout=self.config.verify_timeout)
                for entry in retry:
                    if entry.uuid in found_after:
                        self.report.bump(entry.episode.source, entry.episode.group, "repaired")
                        self.report.bump(entry.episode.source, entry.episode.group, "verified")
                        self.state.mark(
                            source=entry.episode.source,
                            source_id=entry.episode.source_id,
                            group=entry.episode.group,
                            digest=entry.digest,
                            uid=entry.uuid,
                        )
                    else:
                        self.report.fail(
                            source=entry.episode.source,
                            source_id=entry.episode.source_id,
                            group=entry.episode.group,
                            error="episode is still missing from Graphiti after one repair",
                        )
        self.state.save()

    def _print_plan(self, plans: list[Plan], queue: list[BatchEntry], skipped_verified: int) -> None:
        print("ingest plan (dry run)")
        for plan in plans:
            groups: dict[str, list[str]] = {}
            for episode in plan.episodes:
                groups.setdefault(episode.group, []).append(episode.source_id)
            total = sum(len(ids) for ids in groups.values())
            print(f"\n{plan.source}: {total} built, {len(plan.skipped)} skipped across {len(groups)} groups")
            for group, ids in sorted(groups.items()):
                print(f"  {group}: {len(ids)}")
                print(f"    sample: {', '.join(ids[:4])}")
        print(f"\nqueued for write: {len(queue)} (already verified: {skipped_verified})")

    async def run(self, plans: list[Plan]) -> dict[str, object]:
        started_at = utcnow()
        started = self.clock()
        if not self.config.dry_run:
            await self._check_services()

        queue: list[BatchEntry] = []
        seen: set[tuple[str, str]] = set()
        already_verified = 0
        for plan in plans:
            for skip in plan.skipped:
                self.report.bump(skip.source, "unassigned", "skipped")
                if self.config.verbose:
                    self._log(f"skipped {skip.source} {skip.source_id}: {skip.reason}")
            for episode in plan.episodes:
                self.report.bump(episode.source, episode.group, "built")
                try:
                    normalized = normalize_content(episode.content)
                except ValueError:
                    self.report.bump(episode.source, episode.group, "skipped")
                    continue
                digest = content_hash(normalized)
                if self.state.is_verified(episode.source, episode.source_id, digest):
                    already_verified += 1
                    self.report.bump(episode.source, episode.group, "skipped")
                    continue
                identity = (episode.source, episode.source_id)
                if identity in seen:
                    self.report.bump(episode.source, episode.group, "skipped")
                    if self.config.verbose:
                        self._log(f"skipped duplicate source_id {episode.source} {episode.source_id}")
                    continue
                seen.add(identity)
                queue.append(
                    BatchEntry(
                        episode=episode,
                        digest=digest,
                        uuid=episode_uuid(episode.group, digest),
                        content=normalized,
                    )
                )

        for plan in plans:
            groups = {episode.group for episode in plan.episodes}
            self._log(f"{plan.source}: {len(plan.episodes)} built, {len(plan.skipped)} skipped, {len(groups)} groups")

        if self.config.dry_run:
            self._print_plan(plans, queue, already_verified)
            report = self.report.to_dict(
                started_at=started_at, elapsed=self.clock() - started, config=self.config
            )
            return report

        await self._reconcile(queue)

        for offset in range(0, len(queue), self.config.batch):
            batch = queue[offset : offset + self.config.batch]
            self._log(f"batch {offset // self.config.batch + 1}: writing {len(batch)} episode(s)")
            await self._process_batch(batch)

        report = self.report.to_dict(started_at=started_at, elapsed=self.clock() - started, config=self.config)
        path = self.config.resolved_report_path
        _atomic_write(path, json.dumps(report, indent=2, sort_keys=True) + "\n")
        self._log(f"report: {path}")
        totals = report["totals"]
        self._log(
            "done: "
            + ", ".join(f"{name}={totals[name]}" for name in COUNTERS)
            + f", duplicate_rate={report['duplicate_rate']}"
        )
        return report


async def run_plans(plans: list[Plan], config: RunnerConfig, **kwargs) -> dict[str, object]:
    runner = IngestRunner(config, **kwargs)
    return await runner.run(plans)
