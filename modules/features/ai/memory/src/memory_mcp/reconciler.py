"""Background reconciler: pending registry rows become verified graph episodes.

Graphiti accepts an episode into an in-memory queue and exposes no queue status,
so a queued write is not proof of storage. This task polls FalkorDB every
interval for every pending row by `(group_id, exact content)`. Found rows become
`active` with the graph's own uuid; rows absent past a grace period are retried
a bounded number of times and then marked `failed`.

Retries never overlap an in-flight submission for the same content, re-check
presence immediately before resubmitting, and pause while the model endpoint is
unhealthy (rows stay pending rather than failing during an outage). Every graph
call runs off the event loop, a pass is capped, and the first graph outage ends
the pass: once the graph is unreachable, absence cannot be proven for any row.
Writes are guarded on `status='pending'`, so a row tombstoned mid-pass is never
resurrected and never audited.

Each pass then sweeps rows that were tombstoned before their extraction landed
(`tombstoned` with no graph uuid): the episode Graphiti creates afterwards is
still live in the graph, so it is invalidated like a manual tombstone and its
uuid recorded to stop the rescan.
"""

from __future__ import annotations

import asyncio
import os
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone

from .formatting import clip
from .graph import GraphStore, GraphUnavailable
from .graphiti import GraphitiBackend
from .normalize import describe_source
from .readiness import HealthProbes
from .registry import Audit, Registry, RegistryEpisode, age_seconds

DEFAULT_INTERVAL = 10.0
DEFAULT_GRACE = 600.0
DEFAULT_BACKOFF = 60.0
DEFAULT_MAX_RETRIES = 2
# A pass is a burst of blocking Redis round-trips off the event loop; keep it
# short so one pass cannot starve the HTTP server or hold rows for minutes.
MAX_BATCH = 100
DEFAULT_BATCH = MAX_BATCH


@dataclass(frozen=True)
class ReconcilerConfig:
    interval: float = DEFAULT_INTERVAL
    grace: float = DEFAULT_GRACE
    backoff: float = DEFAULT_BACKOFF
    max_retries: int = DEFAULT_MAX_RETRIES
    batch: int = DEFAULT_BATCH

    @classmethod
    def from_env(cls) -> ReconcilerConfig:
        return cls(
            interval=float(os.environ.get("MEMORY_RECONCILE_INTERVAL", str(DEFAULT_INTERVAL))),
            grace=float(os.environ.get("MEMORY_RECONCILE_GRACE", str(DEFAULT_GRACE))),
            backoff=float(os.environ.get("MEMORY_RECONCILE_BACKOFF", str(DEFAULT_BACKOFF))),
            max_retries=int(os.environ.get("MEMORY_RECONCILE_RETRIES", str(DEFAULT_MAX_RETRIES))),
            batch=int(os.environ.get("MEMORY_RECONCILE_BATCH", str(DEFAULT_BATCH))),
        )


class InFlight:
    """Content-keyed guard shared by the write path and retry submissions."""

    def __init__(self) -> None:
        self._keys: set[tuple[str, str]] = set()

    def claim(self, key: tuple[str, str]) -> bool:
        if key in self._keys:
            return False
        self._keys.add(key)
        return True

    def release(self, key: tuple[str, str]) -> None:
        self._keys.discard(key)


def _now() -> datetime:
    return datetime.now(timezone.utc)


class Reconciler:
    def __init__(
        self,
        registry: Registry,
        graph: GraphStore,
        backend: GraphitiBackend,
        probes: HealthProbes,
        *,
        config: ReconcilerConfig | None = None,
        in_flight: InFlight | None = None,
        clock=None,
        now=None,
        sleep=asyncio.sleep,
    ) -> None:
        self.registry = registry
        self.graph = graph
        self.backend = backend
        self.probes = probes
        self.config = config or ReconcilerConfig.from_env()
        self.in_flight = in_flight or InFlight()
        self._clock = clock or time.monotonic
        self._now = now or _now
        self._sleep = sleep
        self._last_attempt: dict[tuple[str, str], float] = {}
        # A pass that cannot read the graph changes nothing and says nothing;
        # keep the reason so the loop can report it instead of stalling quietly.
        self.last_error: str | None = None
        self._reported_error: str | None = None
        # Where the last pending pass stopped, so the next one pages instead of
        # scanning the same rows again.
        self._pending_cursor: tuple[str, str, str] | None = None

    async def reconcile_once(self) -> dict[str, int]:
        counts = {
            "active": 0,
            "waiting": 0,
            "paused": 0,
            "failed": 0,
            "retried": 0,
            "retry_failed": 0,
            "backoff": 0,
            "inflight": 0,
            "unavailable": 0,
            "changed": 0,
            "swept": 0,
        }
        batch = max(1, min(self.config.batch, MAX_BATCH))
        rows = self.registry.pending(limit=batch, after=self._pending_cursor)
        if not rows and self._pending_cursor is not None:
            self._pending_cursor = None
            rows = self.registry.pending(limit=batch)
        if rows:
            # Page, do not restart: rows stuck in `waiting` at the front would
            # otherwise hide a backlog larger than one batch forever. A short
            # page wraps to the front on the next pass.
            last = rows[-1]
            self._pending_cursor = (
                (last.queued_at or last.created_at, last.content_hash, last.group)
                if len(rows) >= batch
                else None
            )
        self.last_error = None
        now = self._now()
        if rows:
            await self._reconcile_pending(rows, counts, now)
            progressed = any(
                counts[name]
                for name in ("active", "failed", "retried", "retry_failed", "swept", "changed")
            )
            if self.last_error is not None or not progressed:
                # An aborted page was not fully inspected, and a page where
                # nothing was due says nothing about the rows before it: go
                # back to the front instead of silently walking past them.
                self._pending_cursor = None
        # The sweep runs after the pending pass and is skipped once the graph
        # proved unreachable: absence is then unknowable for it too.
        if self.last_error is None:
            await self._sweep_tombstoned(counts, now)
        return counts

    async def _reconcile_pending(
        self, rows: list[RegistryEpisode], counts: dict[str, int], now: datetime
    ) -> None:
        healthy = not await self.probes.failures()

        for row in rows:
            key = (row.group, row.content_hash)
            try:
                # Bound to this row's own write: a tombstoned episode with the
                # same content is kept on purpose and is not this extraction.
                found = await asyncio.to_thread(
                    self.graph.episode_for, row.group, row.content, since=row.queued_at
                )
            except GraphUnavailable as exc:
                # Once the graph is unreachable, absence cannot be proven for
                # any later row either: end the pass instead of hammering it.
                self.last_error = str(exc) or type(exc).__name__
                counts["unavailable"] += 1
                return

            if found is not None:
                applied = self.registry.mark_active(
                    row.group,
                    row.content_hash,
                    found.uuid,
                    audit=Audit(
                        actor="reconciler",
                        group=row.group,
                        tool="reconciler",
                        status="active",
                        content_hash=row.content_hash,
                        uuid=row.uuid,
                        details={"graphiti_uuid": found.uuid},
                    ),
                )
                if not applied:
                    counts["changed"] += 1
                    continue
                self._last_attempt.pop(key, None)
                counts["active"] += 1
                continue

            age = age_seconds(row.queued_at, now)
            if age is None:
                age = 0.0
            if age <= self.config.grace:
                counts["waiting"] += 1
                continue

            if not healthy:
                counts["paused"] += 1
                continue

            if row.attempts >= 1 + self.config.max_retries:
                reason = (
                    f"absent from the graph after {row.attempts} attempt(s) and {age:.0f}s"
                )
                applied = self.registry.mark_failed(
                    row.group,
                    row.content_hash,
                    reason,
                    audit=Audit(
                        actor="reconciler",
                        group=row.group,
                        tool="reconciler",
                        status="failed",
                        content_hash=row.content_hash,
                        uuid=row.uuid,
                        details={"attempts": row.attempts, "age_seconds": round(age)},
                    ),
                )
                if not applied:
                    counts["changed"] += 1
                    continue
                counts["failed"] += 1
                continue

            if not self._backoff_elapsed(key):
                counts["backoff"] += 1
                continue

            if not self.in_flight.claim(key):
                counts["inflight"] += 1
                continue

            try:
                # A slow but successful submission must not be duplicated: prove
                # absence again immediately before resubmitting.
                found = await asyncio.to_thread(
                    self.graph.episode_for, row.group, row.content, since=row.queued_at
                )
                if found is not None:
                    applied = self.registry.mark_active(
                        row.group,
                        row.content_hash,
                        found.uuid,
                        audit=Audit(
                            actor="reconciler",
                            group=row.group,
                            tool="reconciler",
                            status="active",
                            content_hash=row.content_hash,
                            uuid=row.uuid,
                            details={"graphiti_uuid": found.uuid},
                        ),
                    )
                    if not applied:
                        counts["changed"] += 1
                        continue
                    self._last_attempt.pop(key, None)
                    counts["active"] += 1
                else:
                    applied_retry, error = await self._resubmit(row)
                    self._last_attempt[key] = self._clock()
                    if not applied_retry:
                        counts["changed"] += 1
                    elif error is None:
                        counts["retried"] += 1
                    else:
                        counts["retry_failed"] += 1
            except GraphUnavailable as exc:
                self.last_error = str(exc) or type(exc).__name__
                counts["unavailable"] += 1
                return
            finally:
                self.in_flight.release(key)

    async def _sweep_tombstoned(self, counts: dict[str, int], now: datetime) -> None:
        """Invalidate graph episodes that landed after their row was tombstoned.

        A tombstone on a row whose extraction had not landed yet cannot reach
        the episode Graphiti creates later, and the row leaves `pending` at
        tombstone time, so the pending pass never sees it. Such a row stays
        `tombstoned` with no graph uuid; this pass finds its episodes anyway,
        invalidates them through the same path a manual tombstone uses, and
        records the newest uuid so the row is not rescanned.
        """
        rows = self.registry.tombstoned_unverified(
            limit=max(1, min(self.config.batch, MAX_BATCH))
        )
        stamp = now.isoformat()
        for row in rows:
            try:
                uuids = await asyncio.to_thread(
                    self.graph.episode_uuids, row.group, row.content
                )
                for uuid_value in uuids:
                    await asyncio.to_thread(
                        self.graph.tombstone, row.group, uuid_value, now=stamp
                    )
            except GraphUnavailable as exc:
                self.last_error = str(exc) or type(exc).__name__
                counts["unavailable"] += 1
                return
            if not uuids:
                continue
            recorded = self.registry.record_graph_uuid(
                row,
                uuids[0],
                audit=Audit(
                    actor="reconciler",
                    group=row.group,
                    tool="reconciler",
                    status="tombstoned",
                    content_hash=row.content_hash,
                    uuid=row.uuid,
                    details={"graphiti_uuid": uuids[0], "late_episodes": len(uuids)},
                ),
            )
            if recorded:
                counts["swept"] += 1

    def _backoff_elapsed(self, key: tuple[str, str]) -> bool:
        last = self._last_attempt.get(key)
        if last is None:
            return True
        return self._clock() - last >= self.config.backoff

    async def _resubmit(self, row: RegistryEpisode) -> tuple[bool, str | None]:
        error: str | None = None
        try:
            await self.backend.add_episode(
                name=row.name,
                episode_body=row.content,
                group_id=row.group,
                source=row.kind,
                reference_time=row.valid_at,
                source_description=describe_source(row.origin, row.origin_ref, row.valid_at),
            )
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # a failed retry is recorded, not raised
            error = clip(str(exc), 300)
        stored = self.registry.record_attempt(
            row.group,
            row.content_hash,
            error=error,
            audit=Audit(
                actor="reconciler",
                group=row.group,
                tool="reconciler",
                status="retried" if error is None else "retry_failed",
                content_hash=row.content_hash,
                uuid=row.uuid,
                details={"error": error} if error else {},
            ),
        )
        if stored is None:
            # The row left `pending` under us (a tombstone, or a duplicate
            # write): drop the result instead of resurrecting it.
            return False, error
        return True, error

    async def run(self) -> None:
        """Poll forever; the wrapper's lifespan cancels this task on shutdown."""
        while True:
            try:
                counts = await self.reconcile_once()
                self.report(counts)
            except asyncio.CancelledError:
                raise
            except Exception as exc:  # one bad pass must not kill the task
                print(f"memory reconciler: {type(exc).__name__}: {exc}", file=sys.stderr)
            await self._sleep(self.config.interval)

    def report(self, counts: dict[str, int]) -> None:
        """Print what a pass achieved, and why a pass achieved nothing.

        Repeated identical failures print once; without this line a registry
        full of `pending` rows looks the same as a healthy idle store.
        """
        error = self.last_error
        if error is None:
            self._reported_error = None
        elif error != self._reported_error:
            print(f"memory reconciler: graph unavailable: {error}", file=sys.stderr)
            self._reported_error = error
        progressed = {
            name: value
            for name, value in counts.items()
            if value and name in ("active", "failed", "retried", "retry_failed", "swept")
        }
        if progressed:
            detail = ", ".join(f"{name}={value}" for name, value in progressed.items())
            print(f"memory reconciler: {detail}", file=sys.stderr)


def build_default(
    registry: Registry,
    *,
    graphiti_url: str,
    redis_url: str,
    llm_url: str,
    embed_url: str,
    embed_model: str | None,
    upstream_timeout: float,
    in_flight: InFlight | None = None,
) -> Reconciler:
    return Reconciler(
        registry,
        GraphStore(redis_url),
        GraphitiBackend(graphiti_url, timeout=upstream_timeout),
        HealthProbes(llm_url=llm_url, embed_url=embed_url, embed_model=embed_model),
        config=ReconcilerConfig.from_env(),
        in_flight=in_flight,
    )
