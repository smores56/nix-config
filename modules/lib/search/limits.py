"""Persisted per-minute rate limit and daily call budget for the search guest.

The state lives in one root-only JSON file and is replaced atomically, so a
restart (or a power cut between writes) never resets the counters: the file the
next boot reads is either the previous complete state or nothing, and a missing
or malformed file fails closed in `searchd` rather than granting a fresh budget.
"""

from __future__ import annotations

import json
import os
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone

STATE_VERSION = 1
MINUTE_SECONDS = 60


class LimitError(RuntimeError):
    """The persisted state cannot be trusted; the caller must block."""


@dataclass(frozen=True)
class Limits:
    per_minute: int
    daily_budget: int


@dataclass(frozen=True)
class State:
    hits: tuple[int, ...]
    day: str
    day_count: int


def empty(now: float) -> State:
    return State(hits=(), day=_day(now), day_count=0)


def _day(now: float) -> str:
    return datetime.fromtimestamp(now, timezone.utc).date().isoformat()


def load(path: str, now: float) -> State:
    """Read the state file; a missing file is a first run, anything else is strict."""
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except FileNotFoundError:
        return empty(now)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise LimitError(f"state {path} is unreadable: {exc}") from exc
    if not isinstance(data, dict) or data.get("v") != STATE_VERSION:
        raise LimitError(f"state {path} has an unexpected shape")
    hits = data.get("hits")
    day = data.get("day")
    day_count = data.get("day_count")
    if not isinstance(hits, list) or not all(isinstance(h, int) and h >= 0 for h in hits):
        raise LimitError(f"state {path} has a malformed hits list")
    if not isinstance(day, str) or not isinstance(day_count, int) or day_count < 0:
        raise LimitError(f"state {path} has a malformed day counter")
    return State(hits=tuple(hits), day=day, day_count=day_count)


def save(path: str, state: State) -> None:
    """Atomically replace the state file at mode 0600."""
    directory = os.path.dirname(path) or "."
    payload = json.dumps(
        {"v": STATE_VERSION, "hits": list(state.hits), "day": state.day, "day_count": state.day_count},
        sort_keys=True,
    )
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".limits.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(payload + "\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    dir_fd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(dir_fd)
    finally:
        os.close(dir_fd)


def admit(state: State, now: float, limits: Limits) -> tuple[bool, str, State]:
    """Reserve one query. Returns (admitted, reason, next_state).

    The counter is advanced and returned even when the call is refused, so a
    caller that persists it cannot retry for free. Future-dated hits (a clock
    that moved backwards) are discarded rather than counted forever.
    """
    if limits.per_minute < 1 or limits.daily_budget < 1:
        raise LimitError("limits must be positive")
    day = _day(now)
    day_count = state.day_count if state.day == day else 0
    hits = tuple(h for h in state.hits if now - MINUTE_SECONDS < h <= now)
    if day_count >= limits.daily_budget:
        return False, "budget", State(hits=hits, day=day, day_count=day_count)
    if len(hits) >= limits.per_minute:
        return False, "rate", State(hits=hits, day=day, day_count=day_count)
    return True, "ok", State(hits=hits + (int(now),), day=day, day_count=day_count + 1)
