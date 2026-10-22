"""Ingest client: plan a corpus, ask the registry what exists, submit the rest.

The wrapper is the single writer. This module builds plans with the source
adapters, hashes each episode, calls the wrapper's loopback
`POST /internal/lookup` in bulk, and submits only missing or failed episodes
through `POST /internal/episodes`. There is no client-side ledger: the registry
is the only state, and the run report is never read back.
"""

from __future__ import annotations

import asyncio
import json
import os
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Awaitable, Callable

import httpx

from .ingest_sources import Episode, Plan
from .normalize import content_hash, episode_uuid, normalize_content

DEFAULT_INTERNAL_URL = "http://127.0.0.1:8182"
DEFAULT_TIMEOUT = 60.0
DEFAULT_CONCURRENCY = 4
LOOKUP_BATCH = 500


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
    internal_url: str = DEFAULT_INTERNAL_URL
    timeout: float = DEFAULT_TIMEOUT
    concurrency: int = DEFAULT_CONCURRENCY
    dry_run: bool = False
    verbose: bool = False
    json_output: bool = False
    report_path: str | None = None

    @property
    def resolved_report_path(self) -> Path:
        return Path(self.report_path).expanduser() if self.report_path else default_state_dir() / f"ingest-{_stamp()}.json"


@dataclass(frozen=True)
class Planned:
    episode: Episode
    digest: str
    uuid: str
    content: str


LookupFn = Callable[[str, list[str]], Awaitable[dict[str, dict[str, object]]]]
SubmitFn = Callable[[dict[str, object]], Awaitable[dict[str, object]]]


class IngestRunner:
    def __init__(
        self,
        config: RunnerConfig,
        *,
        lookup_fn: LookupFn | None = None,
        submit_fn: SubmitFn | None = None,
        clock=time.monotonic,
    ) -> None:
        self.config = config
        self._lookup_fn = lookup_fn
        self._submit_fn = submit_fn
        self.clock = clock

    async def _post(self, path: str, payload: dict[str, object]) -> object:
        url = self.config.internal_url.rstrip("/") + path
        try:
            async with httpx.AsyncClient(timeout=self.config.timeout) as client:
                response = await client.post(url, json=payload)
        except httpx.HTTPError as exc:
            raise IngestError(f"memory wrapper unreachable at {self.config.internal_url}: {exc}") from exc
        if response.status_code != 200:
            try:
                detail = response.json().get("error") or response.text
            except Exception:
                detail = response.text
            raise IngestError(f"{path} returned HTTP {response.status_code}: {str(detail)[:300]}")
        try:
            return response.json()
        except ValueError as exc:
            raise IngestError(f"{path} returned invalid JSON: {exc}") from exc

    async def lookup(self, group: str, hashes: list[str]) -> dict[str, dict[str, object]]:
        if self._lookup_fn is not None:
            return await self._lookup_fn(group, hashes)
        result = await self._post("/internal/lookup", {"group": group, "hashes": hashes})
        if not isinstance(result, dict):
            raise IngestError("/internal/lookup did not return an object")
        return {str(key): dict(value) for key, value in result.items() if isinstance(value, dict)}

    async def submit(self, payload: dict[str, object]) -> dict[str, object]:
        if self._submit_fn is not None:
            return await self._submit_fn(payload)
        result = await self._post("/internal/episodes", payload)
        if not isinstance(result, dict):
            raise IngestError("/internal/episodes did not return an object")
        return dict(result)

    def _plan(self, plans: list[Plan]) -> tuple[list[Planned], dict[str, int]]:
        planned: list[Planned] = []
        counts = {"built": 0, "skipped": 0, "deduplicated": 0, "empty": 0}
        seen: set[tuple[str, str]] = set()
        for plan in plans:
            for skip in plan.skipped:
                counts["skipped"] += 1
                if self.config.verbose:
                    self._log(f"skipped {skip.source} {skip.source_id}: {skip.reason}")
            for warning in plan.warnings:
                self._log(f"warning: {warning}")
            for episode in plan.episodes:
                counts["built"] += 1
                try:
                    normalized = normalize_content(episode.content)
                except ValueError:
                    counts["empty"] += 1
                    continue
                digest = content_hash(normalized)
                identity = (episode.group, digest)
                if identity in seen:
                    counts["deduplicated"] += 1
                    continue
                seen.add(identity)
                planned.append(
                    Planned(
                        episode=episode,
                        digest=digest,
                        uuid=episode_uuid(episode.group, digest),
                        content=normalized,
                    )
                )
        return planned, counts

    def _log(self, message: str) -> None:
        print(f"[ingest] {message}", file=sys.stderr)

    def _payload(self, planned: Planned) -> dict[str, object]:
        episode = planned.episode
        return {
            "group": episode.group,
            "content": planned.content,
            "kind": episode.kind,
            "origin": episode.source,
            "origin_ref": episode.source_id,
            "valid_at": episode.valid_at,
            "tags": list(episode.tags),
            "actor": "ingest",
        }

    async def run(self, plans: list[Plan], *, source_errors: dict[str, str] | None = None) -> dict[str, object]:
        started_at = datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
        started = self.clock()
        planned, counts = self._plan(plans)
        failures: list[dict[str, str]] = []
        for source, error in (source_errors or {}).items():
            failures.append({"source": source, "source_id": "*", "group": "", "error": error})

        report: dict[str, object] = {
            "started_at": started_at,
            "dry_run": self.config.dry_run,
            "totals": {
                **counts,
                "active": 0,
                "pending": 0,
                "tombstoned": 0,
                "missing": 0,
                "submitted": 0,
                "failed": 0,
            },
            "timings": {"lookup_seconds": 0.0, "submit_seconds": 0.0},
            "failures": failures,
            "source_errors": dict(source_errors or {}),
        }

        if self.config.dry_run:
            self._print_plan(plans, planned)
            report["elapsed_seconds"] = round(self.clock() - started, 3)
            return report

        statuses: dict[tuple[str, str], dict[str, object]] = {}
        by_group: dict[str, list[str]] = {}
        for item in planned:
            by_group.setdefault(item.episode.group, []).append(item.digest)

        lookup_started = self.clock()
        for group, digests in sorted(by_group.items()):
            for offset in range(0, len(digests), LOOKUP_BATCH):
                batch = digests[offset : offset + LOOKUP_BATCH]
                try:
                    result = await self.lookup(group, batch)
                except IngestError as exc:
                    for digest in batch:
                        statuses[(group, digest)] = {
                            "status": "lookup_failed",
                            "last_error": str(exc),
                        }
                else:
                    for digest in batch:
                        statuses[(group, digest)] = result.get(
                            digest,
                            {"status": "missing", "uuid": episode_uuid(group, digest)},
                        )
        report["timings"]["lookup_seconds"] = round(self.clock() - lookup_started, 3)

        submit_seconds = 0.0
        semaphore = asyncio.Semaphore(max(1, self.config.concurrency))

        async def submit_one(item: Planned) -> None:
            nonlocal submit_seconds
            state = statuses.get((item.episode.group, item.digest), {})
            status = str(state.get("status") or "missing")
            if status in ("active", "pending", "tombstoned"):
                report["totals"][status] += 1
                return
            if status == "lookup_failed":
                report["totals"]["failed"] += 1
                failures.append(
                    {
                        "source": item.episode.source,
                        "source_id": item.episode.source_id,
                        "group": item.episode.group,
                        "error": str(state.get("last_error") or "lookup failed"),
                    }
                )
                return
            report["totals"]["missing"] += 1
            async with semaphore:
                began = self.clock()
                try:
                    await self.submit(self._payload(item))
                except IngestError as exc:
                    report["totals"]["failed"] += 1
                    failures.append(
                        {
                            "source": item.episode.source,
                            "source_id": item.episode.source_id,
                            "group": item.episode.group,
                            "error": str(exc),
                        }
                    )
                else:
                    report["totals"]["submitted"] += 1
                finally:
                    submit_seconds += self.clock() - began

        await asyncio.gather(*(submit_one(item) for item in planned))
        report["timings"]["submit_seconds"] = round(submit_seconds, 3)
        report["elapsed_seconds"] = round(self.clock() - started, 3)

        path = self.config.resolved_report_path
        _atomic_write(path, json.dumps(report, indent=2, sort_keys=True) + "\n")
        self._log(f"report: {path}")
        totals = report["totals"]
        self._log(
            "done: "
            + ", ".join(f"{name}={totals[name]}" for name in sorted(totals))
            + f", failures={len(failures)}"
        )
        return report

    def _print_plan(self, plans: list[Plan], planned: list[Planned]) -> None:
        stream = sys.stderr if self.config.json_output else sys.stdout
        print("ingest plan (dry run)", file=stream)
        for plan in plans:
            groups: dict[str, int] = {}
            for episode in plan.episodes:
                groups[episode.group] = groups.get(episode.group, 0) + 1
            total = sum(groups.values())
            print(
                f"\n{plan.source}: {total} built, {len(plan.skipped)} skipped across {len(groups)} groups",
                file=stream,
            )
            for group, count in sorted(groups.items()):
                print(f"  {group}: {count}", file=stream)
            if plan.warnings:
                for warning in plan.warnings:
                    print(f"  warning: {warning}", file=stream)
        print(f"\nplanned for lookup: {len(planned)}", file=stream)


async def run_plans(
    plans: list[Plan], config: RunnerConfig, *, source_errors: dict[str, str] | None = None, **kwargs
) -> dict[str, object]:
    return await IngestRunner(config, **kwargs).run(plans, source_errors=source_errors)
