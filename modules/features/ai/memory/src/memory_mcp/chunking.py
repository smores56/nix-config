"""Split markdown into episode-sized sections by top-level heading.

One H2 section is one episode. A section longer than Graphiti's extraction
prompt can take is cut on line boundaries, and a document without H2 headings
is one episode. Fenced code blocks are not scanned for headings: a `## ` in a
shell snippet is sample output, not structure.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

MIN_SECTION_CHARS = 80
MAX_SECTION_CHARS = 8000
SPLIT_TARGET_CHARS = 7500

_H2 = re.compile(r"^##[ \t]+(.+?)[ \t]*#*[ \t]*$")
_SLUG_INVALID = re.compile(r"[^a-z0-9]+")
_FENCE = re.compile(r"^(```|~~~)")


@dataclass(frozen=True)
class Section:
    """One chunk: the heading (empty for a whole document) and its body text."""

    label: str
    key: str
    body: str


def _slug(label: str) -> str:
    slug = _SLUG_INVALID.sub("-", label.strip().lower()).strip("-")
    return (slug or "section")[:60]


def _fence_toggle(line: str, fenced: str | None) -> str | None:
    match = _FENCE.match(line)
    if not match:
        return fenced
    marker = match.group(1)
    if fenced is None:
        return marker
    return None if fenced == marker else fenced


def _split_oversized(body: str) -> list[str]:
    """Cut text near SPLIT_TARGET_CHARS, never mid-line unless one line is huge."""
    pieces: list[str] = []
    current: list[str] = []
    size = 0

    def flush() -> None:
        nonlocal current, size
        if current:
            pieces.append("\n".join(current).strip())
            current = []
            size = 0

    for line in body.splitlines():
        while len(line) > SPLIT_TARGET_CHARS:
            flush()
            pieces.append(line[:SPLIT_TARGET_CHARS].strip())
            line = line[SPLIT_TARGET_CHARS:]
        addition = len(line) + (1 if current else 0)
        if current and size + addition > SPLIT_TARGET_CHARS:
            flush()
            addition = len(line)
        current.append(line)
        size += addition
    flush()
    return [piece for piece in pieces if piece]


def sections_for(text: str, *, min_chars: int = MIN_SECTION_CHARS) -> list[Section]:
    """Return the episode sections for a markdown document."""
    lines = text.replace("\r\n", "\n").replace("\r", "\n").splitlines()
    raw: list[tuple[str, list[str]]] = []
    label = ""
    body: list[str] = []
    fenced: str | None = None
    for line in lines:
        fenced = _fence_toggle(line, fenced)
        match = _H2.match(line) if fenced is None else None
        if match:
            raw.append((label, body))
            label = match.group(1).strip()
            body = []
            continue
        body.append(line)
    raw.append((label, body))

    used: set[str] = set()
    sections: list[Section] = []
    for heading, chunk in raw:
        text_body = "\n".join(chunk).strip()
        if len(text_body) < min_chars:
            continue
        base = _slug(heading) if heading else "body"
        key = base
        suffix = 2
        while key in used:
            key = f"{base}-{suffix}"
            suffix += 1
        used.add(key)
        pieces = _split_oversized(text_body) if len(text_body) > MAX_SECTION_CHARS else [text_body]
        for index, piece in enumerate(pieces, start=1):
            piece_key = key if index == 1 else f"{key}-part-{index}"
            sections.append(Section(label=heading, key=piece_key, body=piece))
    return sections


def context_line(ref: str, title: str, section: str = "") -> str:
    line = f"[{ref}] {title}".strip()
    return f"{line} — {section}" if section else line


def episode_content(ref: str, title: str, section: str, body: str) -> str:
    return f"{context_line(ref, title, section)}\n\n{body}".strip()


def document_title(text: str, fallback: str) -> str:
    """Use the first H1 as the title; fall back to the file or repo name."""
    for line in text.splitlines():
        if line.startswith("# "):
            candidate = " ".join(line[2:].split())
            if candidate:
                return candidate
        if line.strip() and not line.startswith("#"):
            break
    return fallback


def source_ids(base: str, sections: list[Section], *, single_suffix: str = "body") -> list[str]:
    """Stable per-section ids; a one-part document keeps `base#body`."""
    if len(sections) == 1 and sections[0].key == "body":
        return [f"{base}#{single_suffix}"]
    return [f"{base}#{section.key}" for section in sections]
