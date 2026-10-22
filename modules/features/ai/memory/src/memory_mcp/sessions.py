"""Maki sessions: parse the JSONL transcript, summarize it, plan episodes.

Format v2 is a header line (`{"t":"header","v":2,"id":…,"model":…,"cwd":…,
"created_at":<unix>}`) followed by `msg` records whose `content` is a list of
blocks. Only `text` blocks from `user`/`assistant` messages are used: thinking,
tool calls, tool output, and system prompts are dropped. The format matches
`modules/features/ai/maki/maki-session-search.py`; this module does not import
it because that file is a script.

**Budget.** A session can be tens of megabytes, so one session must not be able
to blow the summarizer's token budget. The transcript keeps the first
`MAX_HEAD_MESSAGES` and the last `MAX_TAIL_MESSAGES` messages (the start states
the task, the end states the outcome), truncates each message to
`MAX_MESSAGE_CHARS`, and drops the oldest kept tail messages until the whole
transcript fits `MAX_TRANSCRIPT_CHARS`. Every drop is marked in the transcript
so the model knows text is missing.

**Sampling.** `memory ingest sessions` reads the `--session-limit` (default 50,
which must be positive) most recently modified session files and ranks them by
file mtime, which is cheap for a multi-gigabyte corpus; `valid_at` still comes
from the header's `created_at`. The general `--limit` does not apply to
sessions: `memory ingest all` spends about `--session-limit` summary calls.
A live run prints the sampled count and a token/cost estimate to stderr before
the first model call.

**Dedup.** Episode identity is the registry's content hash, as for every corpus
(see `normalize.py`): a re-run against the same answers submits nothing, and
the runner's `/internal/lookup` skips rows that already exist. A summary cache
(`session_cache.py`, keyed by session id and the SHA-256 of the bounded
transcript) means an unchanged session is not re-summarized, so the model cannot
paraphrase it into a second episode; a changed transcript is re-summarized. The
cache is disposable and never decides duplicates: the registry still does.

**Accepted limits.** Only the cwd's path components are checked for employer
markers; text inside a personal checkout is not scanned for employer content.
A transcript that changed is summarized again (the cache only covers unchanged
ones).

**Privacy.** A session body is personal content. It leaves the machine for
summarization by Neuralwatt through the loopback gateway, and only the summary
and the extracted decisions/constraints/errors/preferences are stored. A
session whose cwd names or is a work checkout is refused before anything is
sent. A session whose cwd does not exist here is also refused, because its work
markers cannot be evaluated: cross-machine sessions must be ingested where
their cwd exists.
"""

from __future__ import annotations

import asyncio
import json
import os
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Awaitable, Callable

from .chunking import episode_content
from .groups import GitError, GroupRefused, derive_group, owner_is_work
from .ingest_sources import Episode, Plan, Skip
from .session_cache import SessionCache, transcript_digest
from .session_summary import (
    DEFAULT_MODEL,
    Extraction,
    Prices,
    SummaryError,
    SummaryItem,
    SummaryResult,
    cost_usd,
    prices_from_env,
)

DEFAULT_SAMPLE = 50
DEFAULT_CONCURRENCY = 3
MAX_HEAD_MESSAGES = 6
MAX_TAIL_MESSAGES = 40
MAX_MESSAGE_CHARS = 4_000
MAX_TRANSCRIPT_CHARS = 24_000
# dry-run only: a 150-300 word summary is roughly this long.
ESTIMATED_COMPLETION_TOKENS = 400
CHARS_PER_TOKEN = 4
SKIP_FILES = frozenset({"cwd_latest.json"})
DEFAULT_TITLE = "Maki session"
MAX_TITLE_CHARS = 200
# (model field, label used in an episode's context line)
CATEGORIES = (
    ("decisions", "decision"),
    ("constraints", "constraint"),
    ("errors", "error"),
    ("preferences", "preference"),
)

SummaryFn = Callable[[str], Awaitable[SummaryResult]]


class SessionError(ValueError):
    """A session file is unreadable or is not a v2 session."""


@dataclass(frozen=True)
class Message:
    role: str
    text: str


@dataclass(frozen=True)
class Session:
    id: str
    path: Path
    cwd: str
    model: str
    created_at: int
    updated_at: int
    title: str
    messages: tuple[Message, ...]
    dropped_lines: int = 0

    @property
    def valid_at(self) -> str:
        if self.created_at <= 0:
            return ""
        return _iso(self.created_at)


@dataclass(frozen=True)
class SessionPlanResult:
    plan: Plan
    report: dict[str, object]


@dataclass
class _Record:
    """One sampled session's contribution, assembled after concurrent work."""

    skip: dict[str, object] | None = None
    item: dict[str, object] | None = None
    episodes: list[Episode] = field(default_factory=list)
    prepared: _Prepared | None = None


@dataclass(frozen=True)
class _Prepared:
    """A parsed, grouped, bounded session ready for summarization."""

    session: Session
    group: str
    transcript: str


def _iso(epoch: int) -> str:
    moment = datetime.fromtimestamp(epoch, tz=timezone.utc)
    return moment.isoformat(timespec="seconds").replace("+00:00", "Z")


def sessions_dirs() -> list[Path]:
    """Maki's session roots, in priority order (`MAKI_SESSIONS_DIR` wins)."""
    override = os.environ.get("MAKI_SESSIONS_DIR", "").strip()
    if override:
        return [Path(override).expanduser()]
    home = Path.home()
    state = Path(os.environ.get("XDG_STATE_HOME", "").strip() or home / ".local" / "state")
    data = Path(os.environ.get("XDG_DATA_HOME", "").strip() or home / ".local" / "share")
    return [
        state / "maki" / "sessions",
        data / "maki" / "sessions",
        home / ".maki" / "sessions",
    ]


def _dirs_label(sessions_dir: str | Path | None) -> str:
    if sessions_dir is not None:
        return str(Path(sessions_dir).expanduser())
    return ", ".join(str(path) for path in sessions_dirs())


def session_files(directory: str | Path | None = None) -> list[Path]:
    """Every `*.jsonl` session file; an explicit missing directory is an error."""
    if directory is not None:
        root = Path(directory).expanduser()
        if not root.is_dir():
            raise SessionError(f"sessions directory not found: {root}")
        roots = [root]
    else:
        roots = sessions_dirs()
    files: list[Path] = []
    for root in roots:
        if not root.is_dir():
            continue
        files.extend(
            path for path in root.glob("*.jsonl") if path.name not in SKIP_FILES and path.is_file()
        )
    return files


def sample_session_files(directory: str | Path | None = None, limit: int | None = DEFAULT_SAMPLE) -> list[Path]:
    """The `limit` most recently modified sessions, newest first."""
    stamped: list[tuple[float, str, Path]] = []
    for path in session_files(directory):
        try:
            stamped.append((path.stat().st_mtime, str(path), path))
        except OSError:
            continue
    stamped.sort(reverse=True)
    if limit is not None and limit > 0:
        stamped = stamped[:limit]
    return [path for _mtime, _name, path in stamped]


def _text_blocks(message: object) -> list[Message]:
    if not isinstance(message, dict):
        return []
    role = message.get("role")
    if role not in ("user", "assistant"):
        return []
    content = message.get("content")
    if isinstance(content, str):
        text = content.strip()
        return [Message(role=str(role), text=text)] if text else []
    if not isinstance(content, list):
        return []
    texts = [
        block["text"].strip()
        for block in content
        if isinstance(block, dict) and block.get("type") == "text" and isinstance(block.get("text"), str)
        if block["text"].strip()
    ]
    return [Message(role=str(role), text=text) for text in texts]


def _normalize_title(value: str) -> str:
    """One printable line, so a title cannot forge a second context line."""
    printable = "".join(character if character.isprintable() else " " for character in value)
    return " ".join(printable.split())[:MAX_TITLE_CHARS]


def _title_fallback(messages: tuple[Message, ...], session_id: str) -> str:
    for message in messages:
        if message.role == "user":
            title = " ".join(message.text.split())[:80]
            if title:
                return title
    return f"{DEFAULT_TITLE} {session_id[:8]}"


def parse_session(path: Path) -> Session:
    """Parse one session file; truncated lines are counted, not fatal.

    The file is streamed line by line: a session can be tens of megabytes and
    holding the whole text is unnecessary.
    """
    header: dict[str, object] | None = None
    title = ""
    updated_at = 0
    messages: list[Message] = []
    dropped = 0
    try:
        handle = path.open("r", encoding="utf-8", errors="replace")
    except OSError as exc:
        raise SessionError(f"unreadable: {exc}") from exc
    try:
        for line in handle:
            if not line.strip():
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                dropped += 1
                continue
            if not isinstance(record, dict):
                dropped += 1
                continue
            kind = record.get("t")
            if kind == "header" and header is None:
                header = record
            elif kind == "meta":
                if isinstance(record.get("title"), str):
                    title = _normalize_title(record["title"])
                if isinstance(record.get("updated_at"), int) and not isinstance(record["updated_at"], bool):
                    updated_at = record["updated_at"]
            elif kind == "msg":
                messages.extend(_text_blocks(record.get("d")))
    except OSError as exc:
        raise SessionError(f"unreadable: {exc}") from exc
    finally:
        handle.close()

    if header is None:
        raise SessionError("missing session header")
    version = header.get("v")
    if version is not None and version != 2:
        raise SessionError(f"unsupported session format v{version}")
    session_id = header.get("id")
    cwd = header.get("cwd")
    if not isinstance(session_id, str) or not session_id.strip():
        raise SessionError("session header has no id")
    if not isinstance(cwd, str) or not cwd.strip():
        raise SessionError("session header has no cwd")
    created = header.get("created_at")
    created_at = created if isinstance(created, int) and not isinstance(created, bool) else 0
    if created_at <= 0:
        try:
            created_at = int(path.stat().st_mtime)
        except OSError:
            created_at = 0
    frozen = tuple(messages)
    return Session(
        id=session_id.strip(),
        path=path,
        cwd=cwd.strip(),
        model=str(header.get("model") or ""),
        created_at=created_at,
        updated_at=updated_at or created_at,
        title=title.strip() or _title_fallback(frozen, session_id),
        messages=frozen,
        dropped_lines=dropped,
    )


def _render(message: Message) -> str:
    text = message.text
    if len(text) > MAX_MESSAGE_CHARS:
        text = text[:MAX_MESSAGE_CHARS].rstrip() + " …"
    return f"{message.role.capitalize()}: {text}"


def bounded_transcript(messages: tuple[Message, ...] | list[Message]) -> tuple[str, int]:
    """A bounded transcript and the number of messages left out.

    First messages and last messages are kept because they carry the task and
    the outcome; the middle is the cheapest thing to drop.
    """
    kept = [message for message in messages if message.text.strip()]
    if not kept:
        return "", 0
    if len(kept) <= MAX_HEAD_MESSAGES + MAX_TAIL_MESSAGES:
        head, tail, omitted = kept, [], 0
    else:
        head = kept[:MAX_HEAD_MESSAGES]
        tail = kept[-MAX_TAIL_MESSAGES:]
        omitted = len(kept) - len(head) - len(tail)

    head_parts = [_render(message) for message in head]
    tail_parts = [_render(message) for message in tail]

    def assemble() -> str:
        blocks = ["\n\n".join(head_parts)]
        if omitted:
            blocks.append(_marker(omitted))
        if tail_parts:
            blocks.append("\n\n".join(tail_parts))
        return "\n\n".join(block for block in blocks if block)

    # The first message states the task and the last states the outcome; those
    # stay. Context between them is dropped in that order of value: extra head
    # messages first (the tail is the recent state), then the oldest tail
    # messages.
    text = assemble()
    while len(text) > MAX_TRANSCRIPT_CHARS:
        if len(head_parts) > 1:
            head_parts.pop()
        elif len(tail_parts) > 1:
            tail_parts.pop(0)
        else:
            break
        omitted += 1
        text = assemble()
    excess = len(text) - MAX_TRANSCRIPT_CHARS
    if excess > 0:
        # One surviving message is still too long: cut its end, not the start.
        if tail_parts:
            tail_parts[-1] = tail_parts[-1][: max(0, len(tail_parts[-1]) - excess)]
        elif head_parts:
            head_parts[-1] = head_parts[-1][: max(0, len(head_parts[-1]) - excess)]
        text = assemble()
    return text, omitted


def _marker(omitted: int) -> str:
    return f"[{omitted} messages omitted here to bound the transcript]"


def session_group(cwd: str) -> str:
    """The project group for a session cwd, with the shared work refusal.

    A session can come from another machine, where its cwd does not exist here.
    The employer markers cannot then be evaluated, so the session is refused:
    cross-machine sessions must be ingested where their cwd exists. A refusal is
    fail-closed, and an existing path is still checked with git below.
    """
    path = Path(cwd).expanduser()
    for part in path.parts:
        if part not in ("/", "") and owner_is_work(part):
            raise GroupRefused(f"session cwd {cwd} names the employer ({part!r})")
    if not path.is_dir():
        raise GroupRefused(
            f"session cwd {cwd} does not exist here; ingest it where its cwd exists "
            "so the work markers can be checked"
        )
    try:
        return derive_group(str(path)).group
    except GitError as exc:
        raise GroupRefused(
            f"cannot verify work status for session cwd {cwd} ({exc})"
        ) from exc


def _categorized(extraction: Extraction) -> list[tuple[str, SummaryItem]]:
    items: list[tuple[str, SummaryItem]] = []
    for field_name, label in CATEGORIES:
        for item in getattr(extraction, field_name):
            items.append((label, item))
    return items


def episodes_for(session: Session, group: str, extraction: Extraction) -> list[Episode]:
    """One episode for the summary and one per explicit item, all same origin."""
    ref = f"maki:{session.id}"
    tags = ("session", session.id)
    common = {
        "source": "session",
        "source_id": session.id,
        "group": group,
        "tags": tags,
        "kind": "text",
        "valid_at": session.valid_at,
    }
    episodes = [
        Episode(
            **common,
            content=episode_content(ref, session.title, "", extraction.summary),
        )
    ]
    for label, item in _categorized(extraction):
        episodes.append(
            Episode(
                **common,
                content=episode_content(ref, session.title, f"{label}: {item.heading}", item.detail),
            )
        )
    return episodes


def _estimate_tokens(transcript: str) -> int:
    return max(1, len(transcript) // CHARS_PER_TOKEN + 1)


def _item_for(session: Session, group: str, omitted: int, transcript: str) -> dict[str, object]:
    return {
        "session_id": session.id,
        "group": group,
        "path": str(session.path),
        "valid_at": session.valid_at,
        "omitted_messages": omitted,
        "transcript_chars": len(transcript),
        "wall_seconds": 0.0,
        "prompt_tokens": 0,
        "completion_tokens": 0,
        "cost_usd": 0.0,
        "attempts": 0,
        "cached": False,
        "episodes": 0,
        "duplicates": 0,
        "submitted": 0,
        "failed": 0,
        "estimated_prompt_tokens": 0,
        "estimated_cost_usd": 0.0,
        "error": "",
    }


def _estimated_cost(tokens: int, prices: Prices) -> float:
    return round(
        cost_usd(
            tokens,
            ESTIMATED_COMPLETION_TOKENS,
            prices.input_per_million,
            prices.output_per_million,
        ),
        6,
    )


def _totals(items: list[dict[str, object]], *, dry_run: bool) -> dict[str, object]:
    prompt = sum(int(item["prompt_tokens"]) for item in items)
    completion = sum(int(item["completion_tokens"]) for item in items)
    # A missing `usage` block means the cost is unknown, not $0.
    known_costs = [
        float(item["cost_usd"])
        for item in items
        if isinstance(item["cost_usd"], (int, float))
    ]
    total_cost: object = (
        round(sum(known_costs), 6)
        if len(known_costs) == len(items)
        else "unknown"
    )
    return {
        "prompt_tokens": prompt,
        "completion_tokens": completion,
        "cost_usd": total_cost,
        "estimated_prompt_tokens": sum(int(item["estimated_prompt_tokens"]) for item in items),
        "estimated_cost_usd": round(
            sum(float(item["estimated_cost_usd"]) for item in items), 6
        ),
        "episodes": sum(int(item["episodes"]) for item in items),
        "duplicates": sum(int(item["duplicates"]) for item in items),
        "submitted": sum(int(item["submitted"]) for item in items),
        "wall_seconds": round(sum(float(item["wall_seconds"]) for item in items), 3),
        "summarized": sum(1 for item in items if not dry_run and not item["error"]),
        "failed": sum(1 for item in items if int(item["failed"]) > 0),
    }


async def build_session_plan(
    *,
    sessions_dir: str | Path | None = None,
    limit: int | None = DEFAULT_SAMPLE,
    summarizer: SummaryFn | None = None,
    dry_run: bool = False,
    concurrency: int = DEFAULT_CONCURRENCY,
    prices: Prices | None = None,
    cache: SessionCache | None = None,
    cache_path: str | Path | None = None,
    clock: Callable[[], float] = time.monotonic,
) -> SessionPlanResult:
    """Parse the sampled sessions and summarize each unless `dry_run`."""
    if not dry_run and summarizer is None:
        raise SessionError("a summarizer is required unless this is a dry run")
    if limit is not None and limit <= 0:
        raise SessionError("--session-limit must be a positive number")
    resolved_prices = prices or prices_from_env()
    paths = sample_session_files(sessions_dir, limit)

    async def prepare(path: Path) -> _Record:
        try:
            session = parse_session(path)
        except SessionError as exc:
            return _Record(skip={"path": str(path), "reason": str(exc)})
        try:
            group = session_group(session.cwd)
        except GroupRefused as exc:
            return _Record(
                skip={"session_id": session.id, "path": str(path), "reason": f"refused: {exc}"}
            )
        transcript, omitted = bounded_transcript(session.messages)
        if not transcript:
            return _Record(
                skip={
                    "session_id": session.id,
                    "path": str(path),
                    "reason": "no text messages in the session",
                }
            )
        item = _item_for(session, group, omitted, transcript)
        tokens = _estimate_tokens(transcript)
        item["estimated_prompt_tokens"] = tokens
        item["estimated_cost_usd"] = _estimated_cost(tokens, resolved_prices)
        prepared = _Prepared(session=session, group=group, transcript=transcript)
        return _Record(item=item, prepared=prepared)

    prepared_outcomes = await asyncio.gather(
        *(prepare(path) for path in paths), return_exceptions=True
    )
    records: list[_Record] = []
    for path, outcome in zip(paths, prepared_outcomes):
        if isinstance(outcome, _Record):
            records.append(outcome)
            continue
        # One bad session must never abort the run; it becomes a skip with the
        # exception type as its reason.
        records.append(
            _Record(
                skip={
                    "path": str(path),
                    "reason": f"unexpected {type(outcome).__name__}: {outcome}",
                }
            )
        )

    if not dry_run and records:
        prepared_records = [record for record in records if record.prepared is not None]
        estimated_tokens = sum(
            int(record.item["estimated_prompt_tokens"])
            for record in prepared_records
            if record.item is not None
        )
        estimated_cost = sum(
            float(record.item["estimated_cost_usd"])
            for record in prepared_records
            if record.item is not None
        )
        print(
            f"[ingest] sessions: {len(paths)} sampled, "
            f"{len(prepared_records)} to summarize; estimated "
            f"{_thousands(estimated_tokens)} input tokens, "
            f"~${estimated_cost:.4f} before the first model call",
            file=sys.stderr,
        )

    if dry_run:
        return _session_plan_result(paths, records, sessions_dir, resolved_prices, dry_run=True, cache_hits=0)

    resolved_cache = cache if cache is not None else SessionCache(cache_path)
    semaphore = asyncio.Semaphore(max(1, concurrency))
    cache_hits = 0

    async def summarize(record: _Record) -> _Record:
        nonlocal cache_hits
        prepared = record.prepared
        item = record.item
        if prepared is None or item is None:
            return record
        session = prepared.session
        async with semaphore:
            digest = transcript_digest(prepared.transcript)
            cached = resolved_cache.get(
                session.id, digest, session_path=session.path
            )
            if cached is not None:
                cache_hits += 1
                item["cached"] = True
                episodes = episodes_for(session, prepared.group, cached)
                item["episodes"] = len(episodes)
                return _Record(item=item, episodes=episodes)
            started = clock()
            try:
                result = await summarizer(prepared.transcript)  # type: ignore[misc]
            except SummaryError as exc:
                item["failed"] = 1
                item["error"] = str(exc)
                item["wall_seconds"] = round(clock() - started, 3)
                return _Record(
                    item=item,
                    skip={
                        "session_id": session.id,
                        "path": str(session.path),
                        "reason": str(exc),
                    },
                )
            episodes = episodes_for(session, prepared.group, result.extraction)
            item.update(
                wall_seconds=result.wall_seconds,
                prompt_tokens=result.prompt_tokens,
                completion_tokens=result.completion_tokens,
                attempts=result.attempts,
                episodes=len(episodes),
            )
            if result.usage_known:
                item["cost_usd"] = round(
                    cost_usd(
                        result.prompt_tokens,
                        result.completion_tokens,
                        resolved_prices.input_per_million,
                        resolved_prices.output_per_million,
                    ),
                    6,
                )
            else:
                item["cost_usd"] = "unknown"
            resolved_cache.put(
                session.id,
                digest,
                session_path=session.path,
                extraction=result.extraction,
            )
            return _Record(item=item, episodes=episodes)

    outcomes = await asyncio.gather(
        *(summarize(record) for record in records), return_exceptions=True
    )
    summarized: list[_Record] = []
    for record, outcome in zip(records, outcomes):
        if isinstance(outcome, _Record):
            summarized.append(outcome)
            continue
        skip = dict(record.skip or {})
        if record.item is not None:
            record.item["failed"] = 1
            record.item["error"] = f"unexpected {type(outcome).__name__}: {outcome}"
            skip["session_id"] = record.item["session_id"]
            skip["path"] = record.item["path"]
        skip["reason"] = f"unexpected {type(outcome).__name__}: {outcome}"
        summarized.append(_Record(item=record.item, skip=skip))

    resolved_cache.save()
    return _session_plan_result(
        paths, summarized, sessions_dir, resolved_prices, dry_run=False, cache_hits=cache_hits
    )


def _session_plan_result(
    paths: list[Path],
    records: list[_Record],
    sessions_dir: str | Path | None,
    prices: Prices,
    *,
    dry_run: bool,
    cache_hits: int,
) -> SessionPlanResult:
    items = [record.item for record in records if record.item is not None]
    skips = [record.skip for record in records if record.skip is not None]
    episodes = [episode for record in records for episode in record.episodes]
    item_ids = {str(item["session_id"]) for item in items}
    parse_skips = sum(
        1 for skip in skips if not skip.get("session_id") or str(skip["session_id"]) not in item_ids
    )

    plan = Plan(
        source="sessions",
        episodes=episodes,
        skipped=[
            Skip("sessions", str(skip.get("session_id") or Path(str(skip["path"])).stem), str(skip["reason"]))
            for skip in skips
        ],
        warnings=[] if paths else ["no Maki session files found in " + _dirs_label(sessions_dir)],
    )
    totals = _totals(items, dry_run=dry_run)
    report: dict[str, object] = {
        "dry_run": dry_run,
        "model": os.environ.get("MEMORY_SUMMARY_MODEL", "").strip() or DEFAULT_MODEL,
        "prices": {
            "input_per_million": prices.input_per_million,
            "output_per_million": prices.output_per_million,
        },
        "sampled": len(paths),
        "parsed": len(items),
        "skipped": parse_skips,
        "cache_hits": cache_hits,
        **totals,
        "items": items,
        "skips": skips,
    }
    return SessionPlanResult(plan=plan, report=report)


def session_observer(report: dict[str, object]) -> Callable[[Episode, str], None]:
    """Count each episode's registry outcome against its session's report item."""
    items = {
        str(item["session_id"]): item
        for item in report.get("items", [])  # type: ignore[union-attr]
        if isinstance(item, dict)
    }

    def observe(episode: Episode, outcome: str) -> None:
        if episode.source != "session":
            return
        item = items.get(episode.source_id)
        if item is None:
            return
        if outcome in ("active", "pending", "tombstoned", "deduplicated"):
            item["duplicates"] = int(item["duplicates"]) + 1
            report["duplicates"] = int(report.get("duplicates") or 0) + 1
        elif outcome == "submitted":
            item["submitted"] = int(item["submitted"]) + 1
            report["submitted"] = int(report.get("submitted") or 0) + 1
        elif outcome in ("failed", "empty"):
            before = int(item["failed"])
            item["failed"] = before + 1
            if before == 0:
                # `failed` in the report counts sessions with a failure, matching
                # the plan-time total; the printed line derives it from items.
                report["failed"] = int(report.get("failed") or 0) + 1
            item["error"] = item["error"] or f"episode {outcome}"

    return observe


def _thousands(value: int) -> str:
    return f"{value / 1000:.0f}k" if value >= 1000 else str(value)


def summary_line(report: dict[str, object]) -> str:
    """One operator-facing line for the run report."""
    sampled = int(report.get("sampled") or 0)
    parsed = int(report.get("parsed") or 0)
    skipped = int(report.get("skipped") or 0)
    if report.get("dry_run"):
        return (
            f"sessions: {sampled} sampled, {parsed} parsed, {skipped} skipped, dry run "
            f"(no model calls; est. {_thousands(int(report.get('estimated_prompt_tokens') or 0))} input tokens, "
            f"~${float(report.get('estimated_cost_usd') or 0):.4f})"
        )
    parts = [f"sessions: {sampled} sampled", f"{int(report.get('summarized') or 0)} summarized"]
    if skipped:
        parts.append(f"{skipped} skipped")
    # Derive failures from the items so a post-plan observation is included; the
    # plan-time field can be stale.
    items = report.get("items")
    if isinstance(items, list):
        failed = sum(
            1
            for item in items
            if isinstance(item, dict) and int(item.get("failed") or 0) > 0
        )
    else:
        failed = int(report.get("failed") or 0)
    if failed:
        parts.append(f"{failed} failed")
    parts.append(
        f"{int(report.get('episodes') or 0)} episodes "
        f"({int(report.get('duplicates') or 0)} duplicates, "
        f"{int(report.get('submitted') or 0)} submitted)"
    )
    wall = float(report.get("wall_seconds") or 0)
    if wall:
        parts.append(f"{wall:.1f}s")
    parts.append(
        f"{_thousands(int(report.get('prompt_tokens') or 0))}/"
        f"{_thousands(int(report.get('completion_tokens') or 0))} tokens"
    )
    cost = report.get("cost_usd")
    if isinstance(cost, (int, float)):
        parts.append(f"${float(cost):.4f}")
    else:
        parts.append("cost unknown")
    return ", ".join(parts)
