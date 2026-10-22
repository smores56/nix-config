"""Disposable cache of session summaries, keyed by session id and transcript hash.

The registry remains the source of truth for duplicates; this is only a cache
that stops an unchanged session from being summarized (and therefore possibly
paraphrased into a second episode) on every run. The file lives in the user's
state dir (`$MEMORY_SESSIONS_CACHE`, else `$XDG_STATE_HOME/memory/sessions.json`,
else `~/.local/state/memory/sessions.json`). It can be deleted at any time.

A cache entry is valid only when the digest of the bounded transcript still
matches. A changed transcript re-summarizes; an unchanged one does not. Entries
whose session file disappeared are pruned, and the cache is capped so it cannot
grow without bound.
"""

from __future__ import annotations

import hashlib
import json
import os
import time
from pathlib import Path

from .session_summary import Extraction, SummaryItem

CACHE_VERSION = 1
MAX_ENTRIES = 500
DEFAULT_NAME = "sessions.json"
MAX_CACHED_ITEMS = 8


def default_cache_path() -> Path:
    override = os.environ.get("MEMORY_SESSIONS_CACHE", "").strip()
    if override:
        return Path(override).expanduser()
    state = os.environ.get("XDG_STATE_HOME", "").strip()
    base = Path(state) if state else Path.home() / ".local" / "state"
    return base / "memory" / DEFAULT_NAME


def transcript_digest(transcript: str) -> str:
    return hashlib.sha256(transcript.encode("utf-8")).hexdigest()


def _items_to_record(items: tuple[SummaryItem, ...]) -> list[dict[str, str]]:
    return [{"heading": item.heading, "detail": item.detail} for item in items]


def _items_from_record(value: object) -> tuple[SummaryItem, ...]:
    if not isinstance(value, list):
        return ()
    items: list[SummaryItem] = []
    for entry in value[:MAX_CACHED_ITEMS]:
        if not isinstance(entry, dict):
            continue
        heading = str(entry.get("heading") or "").strip()
        detail = str(entry.get("detail") or "").strip()
        if heading and detail:
            items.append(SummaryItem(heading=heading, detail=detail))
    return tuple(items)


def _extraction_to_record(extraction: Extraction) -> dict[str, object]:
    return {
        "summary": extraction.summary,
        "decisions": _items_to_record(extraction.decisions),
        "constraints": _items_to_record(extraction.constraints),
        "errors": _items_to_record(extraction.errors),
        "preferences": _items_to_record(extraction.preferences),
    }


def _extraction_from_record(value: object) -> Extraction | None:
    if not isinstance(value, dict):
        return None
    summary = value.get("summary")
    if not isinstance(summary, str) or not summary.strip():
        return None
    return Extraction(
        summary=summary,
        decisions=_items_from_record(value.get("decisions")),
        constraints=_items_from_record(value.get("constraints")),
        errors=_items_from_record(value.get("errors")),
        preferences=_items_from_record(value.get("preferences")),
    )


class SessionCache:
    """One loaded cache file; `save` prunes and caps before writing."""

    def __init__(self, path: Path | str | None = None, *, max_entries: int = MAX_ENTRIES):
        self.path = Path(path).expanduser() if path is not None else default_cache_path()
        self.max_entries = max(1, max_entries)
        self._entries: dict[str, dict[str, object]] = {}
        self._load()

    def _load(self) -> None:
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return
        entries = data.get("entries") if isinstance(data, dict) else None
        if isinstance(entries, dict):
            self._entries = {
                str(key): value for key, value in entries.items() if isinstance(value, dict)
            }

    def get(self, session_id: str, digest: str, *, session_path: Path) -> Extraction | None:
        """The cached extraction for an unchanged transcript, or `None`."""
        entry = self._entries.get(session_id)
        if entry is None or entry.get("digest") != digest:
            return None
        extraction = _extraction_from_record(entry.get("extraction"))
        if extraction is None:
            return None
        # Keep a hit's location and recency current so pruning keeps useful rows.
        entry["session_path"] = str(session_path)
        entry["updated_at"] = int(time.time())
        return extraction

    def put(
        self,
        session_id: str,
        digest: str,
        *,
        session_path: Path,
        extraction: Extraction,
        now: float | None = None,
    ) -> None:
        self._entries[session_id] = {
            "digest": digest,
            "session_path": str(session_path),
            "updated_at": int(now if now is not None else time.time()),
            "extraction": _extraction_to_record(extraction),
        }

    def save(self) -> None:
        """Prune vanished sessions, cap by recency, and write atomically."""
        alive: dict[str, dict[str, object]] = {}
        for session_id, entry in self._entries.items():
            location = entry.get("session_path")
            if not isinstance(location, str) or not Path(location).expanduser().is_file():
                continue
            alive[session_id] = entry
        ordered = sorted(
            alive.items(),
            key=lambda pair: int(pair[1].get("updated_at") or 0),
            reverse=True,
        )
        payload = {
            "version": CACHE_VERSION,
            "entries": dict(ordered[: self.max_entries]),
        }
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            temporary = self.path.with_name(self.path.name + ".tmp")
            temporary.write_text(
                json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8"
            )
            temporary.replace(self.path)
        except OSError:
            # The cache is disposable; a read-only or full state dir is not fatal.
            return
        self._entries = payload["entries"]
