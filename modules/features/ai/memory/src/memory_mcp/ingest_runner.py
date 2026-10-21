"""Batch ingest runner: write through the wrapper, verify in the graph, repair on request.

Graphiti extracts asynchronously and can drop an episode from its in-memory
queue, so a queued write is not a stored episode. Verification reads the
FalkorDB graph directly (exact `id=`/`hash=`/`source`+`source_id` match); only
when FalkorDB is unreachable does it fall back to Graphiti's window-limited
`get_episodes`, and it says so.

Safety rules, in order:

- A write never replaces an episode unless the graph proves the old identity
  (same group, same `source`+`source_id`) is absent. Graph-level removal is not
  available (the wrapper exposes no delete), so rewriting a present or in-flight
  episode is the only way to end up with a duplicate; therefore the default is
  to record a failure and stop.
- Reconcile tombstones only rows the state file says were attempted in an
  earlier run. A first run has nothing to reconcile and audits nothing.
- Repair (`--repair`) is opt-in and still applies only to entries that a prior
  run attempted; `--force --reset-state` archives the state to start over.
- State entries are keyed by `(group, source, source_id)`: a source that moves
  to another group writes there, and a changed hash supersedes the old index
  row (the old graph episode remains, by design).
"""

from __future__ import annotations

import asyncio
import fcntl
import json
import os
import sys
import time
from contextlib import contextmanager
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterator

from .client import ClientConfig, ToolResult, UpstreamError, call_tool
from .graph_index import DEFAULT_REDIS_URL, GraphIndex, Provenance, matches, parse_description
from .graphiti import BackendError, GraphitiBackend
from .ingest_sources import Episode, Plan
from .normalize import content_hash, episode_uuid, normalize_content
from .store import utcnow

DEFAULT_WRAPPER_URL = "http://127.0.0.1:8182/mcp"
DEFAULT_GRAPHITI_URL = "http://127.0.0.1:8184/mcp"
# One in flight keeps Graphiti's queue from dropping work and makes a failure
# attributable to one episode.
DEFAULT_BATCH = 1
# Extraction is one 27B chat call per episode (30-90s, longer under load); the
# grace must outlast a slow extraction before an absent episode is a failure.
DEFAULT_VERIFY_TIMEOUT = 600.0
DEFAULT_POLL_SECONDS = 5.0
DEFAULT_WRITE_TIMEOUT = 90.0
MAX_FETCH = 5000
FALLBACK_FETCH = 50
REPAIR_REASON = "ingest repair: previously attempted write is absent from the graph"
RECONCILE_REASON = "ingest reconcile: previously attempted write never reached the graph"
SUPERSEDE_REASON = "ingest supersede: the source changed and a new version replaced this entry"

COUNTERS = (
    "built",
    "queued",
    "duplicate",
    "skipped",
    "adopted",
    "superseded",
    "reconciled",
    "verified",
    "repaired",
    "failed",
)


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
    redis_url: str = DEFAULT_REDIS_URL
    cwd: str = field(default_factory=os.getcwd)
    batch: int = DEFAULT_BATCH
    verify_timeout: float = DEFAULT_VERIFY_TIMEOUT
    poll_seconds: float = DEFAULT_POLL_SECONDS
    write_timeout: float = DEFAULT_WRITE_TIMEOUT
    dry_run: bool = False
    verbose: bool = False
    repair: bool = False
    force: bool = False
    reset_state: bool = False
    json_output: bool = False
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
    prior_attempt: bool = False


class IngestState:
    """Attempted and verified `(group, source, source_id)` entries.

    The key includes the group because a source can be relabeled or moved (a
    task inheriting a different feature's `repo:` label); a moved source must
    write to its new group instead of being skipped as already verified.
    """

    VERSION = 2

    def __init__(self, path: Path) -> None:
        self.path = path
        self.entries: dict[str, dict[str, object]] = {}
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            payload = {}
        if not isinstance(payload, dict):
            return
        entries = payload.get("entries")
        if isinstance(entries, dict):
            self.entries = {str(key): value for key, value in entries.items() if isinstance(value, dict)}
        # Version 1 keyed verified rows by `(source, source_id)`; migrate them
        # onto the group-aware key so an upgraded install keeps its history.
        verified = payload.get("verified")
        if isinstance(verified, dict):
            for key, value in verified.items():
                if not isinstance(value, dict):
                    continue
                group = str(value.get("group") or "")
                source, _, source_id = str(key).partition("\t")
                if group:
                    self._set(
                        group,
                        source,
                        source_id,
                        {
                            "group": group,
                            "source": source,
                            "source_id": source_id,
                            "hash": str(value.get("hash") or ""),
                            "uuid": str(value.get("uuid") or ""),
                            "attempted": True,
                            "status": "verified",
                            "verified_at": str(value.get("verified_at") or ""),
                        },
                    )

    @staticmethod
    def key(group: str, source: str, source_id: str) -> str:
        return f"{group}\t{source}\t{source_id}"

    def _set(self, group: str, source: str, source_id: str, entry: dict[str, object]) -> None:
        self.entries[self.key(group, source, source_id)] = entry

    def entry(self, group: str, source: str, source_id: str) -> dict[str, object] | None:
        current = self.entries.get(self.key(group, source, source_id))
        return current if current and current.get("group") == group else None

    def is_verified(self, group: str, source: str, source_id: str, digest: str) -> bool:
        current = self.entry(group, source, source_id)
        return bool(
            current
            and current.get("status") == "verified"
            and current.get("hash") == digest
        )

    def was_attempted(self, group: str, source: str, source_id: str) -> bool:
        current = self.entry(group, source, source_id)
        return bool(current and current.get("attempted"))

    def mark_attempted(self, *, group: str, source: str, source_id: str, digest: str, uid: str) -> None:
        current = self.entry(group, source, source_id) or {}
        self._set(
            group,
            source,
            source_id,
            {
                **current,
                "group": group,
                "source": source,
                "source_id": source_id,
                "hash": digest,
                "uuid": uid,
                "attempted": True,
                "status": "attempted",
                "attempted_at": utcnow(),
            },
        )

    def mark_verified(self, *, group: str, source: str, source_id: str, digest: str, uid: str) -> None:
        current = self.entry(group, source, source_id) or {}
        self._set(
            group,
            source,
            source_id,
            {
                **current,
                "group": group,
                "source": source,
                "source_id": source_id,
                "hash": digest,
                "uuid": uid,
                "attempted": True,
                "status": "verified",
                "verified_at": utcnow(),
                "last_error": "",
            },
        )

    def mark_failed(self, *, group: str, source: str, source_id: str, digest: str, uid: str, error: str) -> None:
        current = self.entry(group, source, source_id) or {}
        try:
            failures = int(current.get("failures") or 0)
        except (TypeError, ValueError):
            failures = 0
        self._set(
            group,
            source,
            source_id,
            {
                **current,
                "group": group,
                "source": source,
                "source_id": source_id,
                "hash": digest,
                "uuid": uid,
                "attempted": True,
                "status": "failed",
                "failed_at": utcnow(),
                "failures": failures + 1,
                "last_error": error[:300],
            },
        )

    def save(self) -> None:
        _atomic_write(
            self.path,
            json.dumps({"version": self.VERSION, "entries": self.entries}, indent=2, sort_keys=True) + "\n",
        )

    def reset(self) -> Path | None:
        """Archive the state file so the next run starts as a first run.

        The archive keeps the audit trail; a reset is the documented way to
        re-attempt every planned episode (and the only way to re-write one the
        state still calls verified).
        """
        self.entries = {}
        if not self.path.exists():
            return None
        backup = self.path.with_name(f"{self.path.name}.bak-{_stamp()}")
        self.path.replace(backup)
        return backup

    @contextmanager
    def lock(self) -> Iterator[None]:
        """Exclusive, non-blocking lock so two ingests cannot interleave writes."""
        self.path.parent.mkdir(parents=True, exist_ok=True)
        lock_path = self.path.with_name(self.path.name + ".lock")
        handle = lock_path.open("w", encoding="utf-8")
        try:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError as exc:
                raise IngestError(
                    f"another ingest holds {lock_path}; wait for it to finish instead of running two"
                ) from exc
            yield
        finally:
            try:
                fcntl.flock(handle, fcntl.LOCK_UN)
            finally:
                handle.close()


class Report:
    def __init__(self) -> None:
        self.sources: dict[str, dict[str, dict[str, int]]] = {}
        self.failures: list[dict[str, str]] = []
        self.source_errors: dict[str, str] = {}
        self.presence = "falkordb"

    def bump(self, source: str, group: str, counter: str, amount: int = 1) -> None:
        bucket = self.sources.setdefault(source, {}).setdefault(group, {name: 0 for name in COUNTERS})
        bucket[counter] = bucket.get(counter, 0) + amount

    def fail(self, *, source: str, source_id: str, group: str, error: str) -> None:
        self.bump(source, group, "failed")
        self.failures.append({"source": source, "source_id": source_id, "group": group, "error": error[:300]})

    def fail_source(self, source: str, error: str) -> None:
        """A corpus source that could not be read at all; the run continues."""
        self.source_errors[source] = error[:300]
        self.bump(source, "source", "failed")
        self.failures.append({"source": source, "source_id": "*", "group": "source", "error": error[:300]})

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
                "error": self.source_errors.get(source, ""),
                "groups": dict(sorted(groups.items())),
            }
        attempted = overall["queued"] + overall["duplicate"]
        return {
            "started_at": started_at,
            "finished_at": utcnow(),
            "elapsed_seconds": round(elapsed, 1),
            "batch": config.batch,
            "verify_timeout_seconds": config.verify_timeout,
            "presence": self.presence,
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
        index: GraphIndex | None = None,
        sleep=asyncio.sleep,
        clock=time.monotonic,
    ) -> None:
        self.config = config
        self.backend = backend or GraphitiBackend(config.graphiti_url, timeout=60.0)
        self.call_tool_fn = call_tool_fn
        self.state = state or IngestState(config.resolved_state_path)
        self.index = index or GraphIndex(config.redis_url)
        self.sleep = sleep
        self.clock = clock
        self.report = Report()
        self._fallback_groups: set[str] = set()

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
        arguments: dict[str, object] = {"content": entry.content}
        if entry.episode.tags:
            arguments["tags"] = list(entry.episode.tags)
        result: ToolResult = await self.call_tool_fn(
            self._config_for(
                group=entry.episode.group,
                source=entry.episode.source,
                source_id=entry.episode.source_id,
            ),
            "memory_write",
            arguments,
        )
        if result.is_error:
            raise IngestError(result.text.strip() or "memory_write failed")
        return _episode_status(result.text)

    async def _tombstone(self, group: str, ref: str, *, reason: str) -> None:
        result = await self.call_tool_fn(
            self._config_for(group=group),
            "memory_tombstone",
            {"ref": ref, "reason": reason},
        )
        if result.is_error:
            raise IngestError(result.text.strip() or "memory_tombstone failed")

    async def _tombstone_entry(self, entry: BatchEntry, *, reason: str) -> bool:
        """Tombstone the wrapper's index row for this entry; False when absent."""
        return await self._tombstone_index(entry.episode.group, entry.uuid, reason=reason)

    async def _tombstone_index(self, group: str, ref: str, *, reason: str) -> bool:
        try:
            await self._tombstone(group, ref, reason=reason)
        except (IngestError, UpstreamError) as exc:
            if "no stored episode" in str(exc):
                return False
            raise
        return True

    async def _fetch_episodes(self, group: str) -> list[dict[str, object]]:
        """Fallback only: a window-limited read through Graphiti's MCP server."""
        page = FALLBACK_FETCH
        while True:
            episodes = await self.backend.get_episodes([group], page)
            if len(episodes) < page or page >= MAX_FETCH:
                return episodes
            page = min(MAX_FETCH, page * 2)

    async def _presence(self, group: str) -> tuple[set[Provenance], str] | None:
        """Presence tokens for one group, or None when neither read is available.

        The FalkorDB query is exact; `get_episodes` is the documented fallback
        (window-limited) and is reported so an operator knows the run was
        approximate.
        """
        descriptions = await asyncio.to_thread(self.index.descriptions, group)
        if descriptions is not None:
            return {parse_description(description) for description in descriptions}, "falkordb"
        if group not in self._fallback_groups:
            self._fallback_groups.add(group)
            self._log(f"presence {group}: FalkorDB {self.index.url} unavailable; falling back to get_episodes (window-limited)")
        self.report.presence = "get_episodes"
        try:
            episodes = await self._fetch_episodes(group)
        except BackendError as exc:
            self._log(f"presence {group}: {exc}")
            return None
        return {
            parse_description(str(episode.get("source_description") or episode.get("sourceDescription") or ""))
            for episode in episodes
        }, "get_episodes"

    @staticmethod
    def _present(entry: BatchEntry, provenance: set[Provenance]) -> bool:
        return any(
            matches(
                candidate,
                uid=entry.uuid,
                digest=entry.digest,
                source=entry.episode.source,
                source_id=entry.episode.source_id,
            )
            for candidate in provenance
        )

    async def _reconcile(self, queue: list[BatchEntry]) -> list[BatchEntry]:
        """Adopt or revive rows a previous run attempted; never audit a first run.

        For every group independently: an episode the graph already holds is
        adopted (the wrapper row is marked verified instead of re-queued), and
        an absent one gets its index row tombstoned so the new write is a queue
        rather than a duplicate. Groups that cannot be read leave their entries
        unwritten instead of risking a second graph episode.
        """
        attempted = [entry for entry in queue if entry.prior_attempt]
        if not attempted:
            if queue:
                self._log("reconcile: nothing attempted before; skipping (first run)")
            return queue

        decisions: dict[str, str] = {}
        by_group: dict[str, list[BatchEntry]] = {}
        for entry in attempted:
            by_group.setdefault(entry.episode.group, []).append(entry)

        for group, entries in by_group.items():
            presence = await self._presence(group)
            for entry in entries:
                # A changed hash is a new version of the same plan entry. Its
                # content differs from anything already queued, so writing it
                # cannot duplicate an episode; the previous index row is marked
                # superseded (the graph episode remains by design).
                current = self.state.entry(group, entry.episode.source, entry.episode.source_id) or {}
                previous_digest = str(current.get("hash") or "")
                if previous_digest and previous_digest != entry.digest:
                    previous_uuid = str(current.get("uuid") or "")
                    if previous_uuid:
                        try:
                            if await self._tombstone_index(group, previous_uuid, reason=SUPERSEDE_REASON):
                                self.report.bump(entry.episode.source, group, "superseded")
                        except (IngestError, UpstreamError) as exc:
                            self._log(f"supersede {entry.episode.source_id}: {exc}")
                    decisions[entry.uuid] = "write"
                    continue
                if presence is None:
                    decisions[entry.uuid] = "unknown"
                    continue
                provenance, _backend = presence
                if self._present(entry, provenance):
                    decisions[entry.uuid] = "adopted"
                    continue
                try:
                    await self._tombstone_entry(entry, reason=RECONCILE_REASON)
                except (IngestError, UpstreamError) as exc:
                    self._log(f"reconcile {entry.episode.source_id}: {exc}")
                    decisions[entry.uuid] = "unknown"
                    continue
                self.report.bump(entry.episode.source, entry.episode.group, "reconciled")
                decisions[entry.uuid] = "write"
                if self.config.verbose:
                    self._log(f"reconciled {entry.episode.source} {entry.episode.source_id}")

        remaining: list[BatchEntry] = []
        for entry in queue:
            decision = decisions.get(entry.uuid, "write")
            if decision == "adopted":
                self.report.bump(entry.episode.source, entry.episode.group, "adopted")
                self.report.bump(entry.episode.source, entry.episode.group, "skipped")
                self.state.mark_verified(
                    group=entry.episode.group,
                    source=entry.episode.source,
                    source_id=entry.episode.source_id,
                    digest=entry.digest,
                    uid=entry.uuid,
                )
                if self.config.verbose:
                    self._log(f"adopted {entry.episode.source} {entry.episode.source_id} (already in the graph)")
                continue
            if decision == "unknown":
                self.report.fail(
                    source=entry.episode.source,
                    source_id=entry.episode.source_id,
                    group=entry.episode.group,
                    error=(
                        "cannot prove the previously attempted episode is absent (FalkorDB and "
                        "Graphiti are both unreadable); not rewritten"
                    ),
                )
                continue
            remaining.append(entry)
        self.state.save()
        return remaining

    async def _verify(self, entries: list[BatchEntry], *, timeout: float) -> tuple[set[str], set[str]]:
        """Poll presence until every identity appears, or the grace period ends."""
        wanted = {entry.uuid: entry for entry in entries}
        by_group: dict[str, list[BatchEntry]] = {}
        for entry in entries:
            by_group.setdefault(entry.episode.group, []).append(entry)
        found: set[str] = set()
        deadline = self.clock() + timeout

        while True:
            for group, group_entries in by_group.items():
                if all(entry.uuid in found for entry in group_entries):
                    continue
                presence = await self._presence(group)
                if presence is None:
                    continue
                provenance, _backend = presence
                for entry in group_entries:
                    if self._present(entry, provenance):
                        found.add(entry.uuid)
            missing = set(wanted) - found
            if not missing:
                break
            remaining = deadline - self.clock()
            if remaining <= 0:
                break
            await self.sleep(min(self.config.poll_seconds, remaining))
        return found, set(wanted) - found

    def _mark_verified(self, entry: BatchEntry) -> None:
        self.report.bump(entry.episode.source, entry.episode.group, "verified")
        self.state.mark_verified(
            group=entry.episode.group,
            source=entry.episode.source,
            source_id=entry.episode.source_id,
            digest=entry.digest,
            uid=entry.uuid,
        )

    def _mark_failed(self, entry: BatchEntry, error: str) -> None:
        self.report.fail(
            source=entry.episode.source,
            source_id=entry.episode.source_id,
            group=entry.episode.group,
            error=error,
        )
        self.state.mark_failed(
            group=entry.episode.group,
            source=entry.episode.source,
            source_id=entry.episode.source_id,
            digest=entry.digest,
            uid=entry.uuid,
            error=error,
        )

    async def _repair(self, entry: BatchEntry, timeout: float) -> bool:
        """Rewrite one absent, previously attempted entry after an exact re-check.

        Returns True when the entry was handled (adopted or rewritten), False
        when it stays failed. The presence check is repeated immediately before
        the tombstone: Graphiti extracts asynchronously, so an episode that was
        merely in flight at the grace deadline can land at any moment, and
        rewriting it is exactly how a duplicate is created.
        """
        if not self.config.repair:
            return False
        if not entry.prior_attempt:
            self._log(f"repair {entry.episode.source_id}: no earlier attempt in the state; refusing to rewrite")
            return False
        presence = await self._presence(entry.episode.group)
        if presence is None or presence[1] != "falkordb":
            self._log(f"repair {entry.episode.source_id}: FalkorDB unavailable; refusing an approximate repair")
            return False
        provenance, _backend = presence
        if self._present(entry, provenance):
            self._log(f"repair {entry.episode.source_id}: the episode landed during the grace; not rewriting")
            self._mark_verified(entry)
            self.report.bump(entry.episode.source, entry.episode.group, "adopted")
            return True
        try:
            await self._tombstone_entry(entry, reason=REPAIR_REASON)
            self.state.mark_attempted(
                group=entry.episode.group,
                source=entry.episode.source,
                source_id=entry.episode.source_id,
                digest=entry.digest,
                uid=entry.uuid,
            )
            self.state.save()
            status = await self._write(entry)
        except (IngestError, UpstreamError) as exc:
            self._mark_failed(entry, f"repair failed: {exc}")
            return True
        if status != "queued":
            self._log(f"repair rewritten as {status} for {entry.episode.source_id}")
        found, _missing = await self._verify([entry], timeout=timeout)
        if entry.uuid in found:
            self.report.bump(entry.episode.source, entry.episode.group, "repaired")
            self._mark_verified(entry)
        else:
            self._mark_failed(
                entry,
                "episode is still absent from FalkorDB after one repair; not rewritten again",
            )
        return True

    async def _process_batch(self, batch: list[BatchEntry]) -> None:
        written: list[BatchEntry] = []
        for entry in batch:
            self.state.mark_attempted(
                group=entry.episode.group,
                source=entry.episode.source,
                source_id=entry.episode.source_id,
                digest=entry.digest,
                uid=entry.uuid,
            )
            self.state.save()
            try:
                status = await self._write(entry)
            except (IngestError, UpstreamError) as exc:
                self._mark_failed(entry, str(exc))
                self._log(f"write failed {entry.episode.source_id}: {exc}")
                continue
            self.report.bump(entry.episode.source, entry.episode.group, status)
            written.append(entry)
            if self.config.verbose:
                self._log(f"{status} {entry.episode.source} {entry.episode.source_id} -> {entry.episode.group}")
        if not written:
            self.state.save()
            return

        found, missing = await self._verify(written, timeout=self.config.verify_timeout)
        for entry in written:
            if entry.uuid in found:
                self._mark_verified(entry)

        repair_set = [entry for entry in written if entry.uuid in missing]
        if repair_set:
            self._log(
                f"verification missed {len(repair_set)} episode(s) after the "
                f"{self.config.verify_timeout:g}s grace"
            )
            for entry in repair_set:
                if self.config.repair:
                    handled = await self._repair(entry, self.config.verify_timeout)
                    if handled:
                        continue
                self._mark_failed(
                    entry,
                    (
                        "absent from the graph after the grace period; the index row was left in place "
                        "so a re-run reconciles it (use --repair to rewrite it once, or "
                        "--force --reset-state to start over)"
                    ),
                )
        self.state.save()

    def _print_plan(self, plans: list[Plan], queue: list[BatchEntry], skipped_verified: int) -> None:
        stream = sys.stderr if self.config.json_output else sys.stdout
        print("ingest plan (dry run)", file=stream)
        for plan in plans:
            groups: dict[str, list[str]] = {}
            for episode in plan.episodes:
                groups.setdefault(episode.group, []).append(episode.source_id)
            total = sum(len(ids) for ids in groups.values())
            print(
                f"\n{plan.source}: {total} built, {len(plan.skipped)} skipped across {len(groups)} groups",
                file=stream,
            )
            for group, ids in sorted(groups.items()):
                print(f"  {group}: {len(ids)}", file=stream)
                print(f"    sample: {', '.join(ids[:4])}", file=stream)
            if plan.warnings:
                for warning in plan.warnings:
                    print(f"  warning: {warning}", file=stream)
        print(f"\nqueued for write: {len(queue)} (already verified: {skipped_verified})", file=stream)

    def _build_queue(self, plans: list[Plan]) -> tuple[list[BatchEntry], int]:
        queue: list[BatchEntry] = []
        seen: set[tuple[str, str, str]] = set()
        already_verified = 0
        for plan in plans:
            for skip in plan.skipped:
                self.report.bump(skip.source, "unassigned", "skipped")
                if self.config.verbose:
                    self._log(f"skipped {skip.source} {skip.source_id}: {skip.reason}")
            for warning in plan.warnings:
                self._log(f"warning: {warning}")
            for episode in plan.episodes:
                self.report.bump(episode.source, episode.group, "built")
                try:
                    normalized = normalize_content(episode.content)
                except ValueError:
                    self.report.bump(episode.source, episode.group, "skipped")
                    continue
                digest = content_hash(normalized)
                if self.state.is_verified(episode.group, episode.source, episode.source_id, digest):
                    already_verified += 1
                    self.report.bump(episode.source, episode.group, "skipped")
                    continue
                identity = (episode.group, episode.source, episode.source_id)
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
                        prior_attempt=self.state.was_attempted(
                            episode.group, episode.source, episode.source_id
                        ),
                    )
                )
        return queue, already_verified

    async def run(self, plans: list[Plan], *, source_errors: dict[str, str] | None = None) -> dict[str, object]:
        started_at = utcnow()
        started = self.clock()
        if self.config.force and not self.config.reset_state:
            raise IngestError("--force requires --reset-state: a reset is the only way to re-attempt verified entries")
        if self.config.reset_state and not self.config.force:
            raise IngestError("--reset-state requires --force: it archives the state and re-attempts every entry")
        if not self.config.dry_run:
            await self._check_services()

        for source, error in (source_errors or {}).items():
            self.report.fail_source(source, error)

        if self.config.dry_run:
            queue, already_verified = self._build_queue(plans)
            for plan in plans:
                groups = {episode.group for episode in plan.episodes}
                self._log(
                    f"{plan.source}: {len(plan.episodes)} built, {len(plan.skipped)} skipped, {len(groups)} groups"
                )
            self._print_plan(plans, queue, already_verified)
            return self.report.to_dict(
                started_at=started_at, elapsed=self.clock() - started, config=self.config
            )

        with self.state.lock():
            if self.config.reset_state:
                backup = self.state.reset()
                self._log(
                    f"state reset: archived {backup}" if backup else "state reset: no state file to archive"
                )
            queue, already_verified = self._build_queue(plans)
            for plan in plans:
                groups = {episode.group for episode in plan.episodes}
                self._log(
                    f"{plan.source}: {len(plan.episodes)} built, {len(plan.skipped)} skipped, {len(groups)} groups"
                )

            queue = await self._reconcile(queue)

            batch_size = max(1, self.config.batch)
            for offset in range(0, len(queue), batch_size):
                batch = queue[offset : offset + batch_size]
                self._log(f"batch {offset // batch_size + 1}: writing {len(batch)} episode(s)")
                await self._process_batch(batch)

            report = self.report.to_dict(
                started_at=started_at, elapsed=self.clock() - started, config=self.config
            )
            path = self.config.resolved_report_path
            _atomic_write(path, json.dumps(report, indent=2, sort_keys=True) + "\n")
            self._log(f"report: {path}")
            totals = report["totals"]
            self._log(
                "done: "
                + ", ".join(f"{name}={totals[name]}" for name in COUNTERS)
                + f", duplicate_rate={report['duplicate_rate']}, presence={report['presence']}"
            )
            return report


async def run_plans(
    plans: list[Plan], config: RunnerConfig, *, source_errors: dict[str, str] | None = None, **kwargs
) -> dict[str, object]:
    runner = IngestRunner(config, **kwargs)
    return await runner.run(plans, source_errors=source_errors)
