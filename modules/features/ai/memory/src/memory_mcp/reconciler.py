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
        }
        rows = self.registry.pending(limit=max(1, min(self.config.batch, MAX_BATCH)))
        if not rows:
            return counts
        healthy = not await self.probes.failures()
        now = self._now()

        for row in rows:
            key = (row.group, row.content_hash)
            try:
                found = await asyncio.to_thread(self.graph.episode_for, row.group, row.content)
            except GraphUnavailable:
                # Once the graph is unreachable, absence cannot be proven for
                # any later row either: end the pass instead of hammering it.
                counts["unavailable"] += 1
                break

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

            age = age_seconds(row.created_at, now)
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
                    self.graph.episode_for, row.group, row.content
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
            except GraphUnavailable:
                counts["unavailable"] += 1
                break
            finally:
                self.in_flight.release(key)

        return counts

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
                await self.reconcile_once()
            except asyncio.CancelledError:
                raise
            except Exception as exc:  # one bad pass must not kill the task
                print(f"memory reconciler: {type(exc).__name__}: {exc}", file=sys.stderr)
            await self._sleep(self.config.interval)


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
