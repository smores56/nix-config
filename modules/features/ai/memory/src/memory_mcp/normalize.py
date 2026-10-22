"""Content normalization, hashing, and deterministic episode identity."""

from __future__ import annotations

import hashlib
import re
import uuid

_INLINE_WHITESPACE = re.compile(r"[ \t\f\v]+")
_BLANK_RUN = re.compile(r"\n{3,}")
_TAG_INVALID = re.compile(r"[^a-z0-9_-]+")
MAX_TAGS = 8
MAX_TAG_LENGTH = 24
MAX_NAME_LENGTH = 80


def normalize_content(content: str) -> str:
    """Canonical text used for hashing and storage.

    Line structure is meaningful for markdown, so only line endings, trailing
    whitespace, runs of spaces, and extra blank lines are collapsed. Two spellings
    that differ only in formatting therefore dedupe to one episode.
    """
    if not isinstance(content, str):
        raise ValueError("content must be a string")
    # SQLite stores TEXT as a C string: a NUL truncates the row silently, so the
    # stored content would no longer hash to its own identity.
    if "\x00" in content:
        raise ValueError("content contains a NUL byte (U+0000), which a memory cannot store")
    text = content.replace("\r\n", "\n").replace("\r", "\n")
    lines = [_INLINE_WHITESPACE.sub(" ", line).rstrip() for line in text.split("\n")]
    text = "\n".join(lines)
    text = _BLANK_RUN.sub("\n\n", text).strip()
    if not text:
        raise ValueError("content is empty after normalization")
    return text


def content_hash(normalized: str) -> str:
    return hashlib.sha256(normalized.encode("utf-8")).hexdigest()


def episode_uuid(group: str, digest: str) -> str:
    """Idempotent episode identity: the same group+content always maps to one uuid."""
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"{group}:{digest}"))


def episode_name(normalized: str, digest: str) -> str:
    for line in normalized.splitlines():
        candidate = " ".join(line.split())
        if candidate:
            return candidate[:MAX_NAME_LENGTH]
    return f"memory {digest[:12]}"


def describe_source(origin: str, origin_ref: str, valid_at: str = "") -> str:
    """A short human-readable label for Graphiti's `source_description`.

    Nothing here is parsed back: identity and provenance live in the registry.
    The description exists only so a graph inspector can tell where an episode
    came from.
    """
    label = " ".join(f"{origin} {origin_ref}".split())
    day = (valid_at or "")[:10]
    if day:
        label = f"{label} ({day})"
    return label[:200] or origin


def normalize_tags(tags: list[str] | None) -> list[str]:
    if not tags:
        return []
    cleaned: list[str] = []
    for tag in tags:
        candidate = _TAG_INVALID.sub("-", str(tag).strip().lower()).strip("-")
        candidate = candidate[:MAX_TAG_LENGTH]
        if candidate and candidate not in cleaned:
            cleaned.append(candidate)
        if len(cleaned) >= MAX_TAGS:
            break
    return cleaned
