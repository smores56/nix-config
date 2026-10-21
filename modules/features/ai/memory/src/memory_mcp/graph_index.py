"""Exact episode-presence checks read straight from FalkorDB.

Graphiti's `get_episodes` is a paged, window-limited read: it cannot prove that
an episode is absent, and a large group pushes older episodes out of the
window. The ingest therefore asks the graph itself. Graphiti writes each group
into its own FalkorDB graph named after the group id, and every wrapper write
carries `hash=<digest>; id=<uuid5>; ...; source=<source>; source_id=<id>` in
`source_description`, so one `MATCH (e:Episodic)` query answers exactly.

The read is read-only and optional: when FalkorDB is unreachable the runner
falls back to `get_episodes`, says so, and refuses repairs, because an
approximate absence is not enough to risk a second graph episode.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

DEFAULT_REDIS_URL = "redis://127.0.0.1:6379"
EPISODIC_QUERY = "MATCH (e:Episodic) RETURN e.uuid, e.source_description"
SOCKET_TIMEOUT = 5.0
# FalkorDB answers an unknown graph with an error; that is an empty group, not
# an unreachable database.
_UNKNOWN_GRAPH = ("invalid graph name", "no such graph", "graph not found")

_ID_TOKEN = re.compile(r"(?:^|;\s*)id=([0-9a-fA-F-]{36})")
_HASH_TOKEN = re.compile(r"(?:^|;\s*)hash=([0-9a-f]{64})")


@dataclass(frozen=True)
class Provenance:
    """Identity tokens parsed out of one `source_description`."""

    id: str = ""
    hash: str = ""
    source: str = ""
    source_id: str = ""


def parse_description(description: str) -> Provenance:
    tokens: dict[str, str] = {}
    for part in description.split("; "):
        key, separator, value = part.partition("=")
        if separator:
            tokens.setdefault(key.strip(), value.strip())
    ids = _ID_TOKEN.findall(description)
    hashes = _HASH_TOKEN.findall(description)
    return Provenance(
        id=ids[0] if ids else tokens.get("id", ""),
        hash=hashes[0] if hashes else tokens.get("hash", ""),
        source=tokens.get("source", ""),
        source_id=tokens.get("source_id", ""),
    )


def matches(
    provenance: Provenance,
    *,
    uid: str = "",
    digest: str = "",
    source: str = "",
    source_id: str = "",
) -> bool:
    """Whether a stored episode is exactly the version the caller means.

    The uuid5 identity is exact and the content hash catches an identical body
    under a different id. `(source, source_id)` names the plan entry, not the
    version: matching it alone would let a changed episode look present because
    the previous version is still in the graph, so it is only accepted for a
    description with no hash at all (which no wrapper write can produce).
    """
    if uid and provenance.id and provenance.id == uid:
        return True
    if digest and provenance.hash and provenance.hash == digest:
        return True
    return bool(
        source
        and source_id
        and not provenance.hash
        and provenance.source == source
        and provenance.source_id == source_id
    )


def _text(value: object) -> str:
    """FalkorDB bulk strings arrive as bytes unless the client decodes them."""
    return value.decode("utf-8", "replace") if isinstance(value, bytes) else str(value)


def _rows(reply: object) -> list[list[object]]:
    """FalkorDB replies with `[header, rows, statistics]` for a RETURN query."""
    if isinstance(reply, list) and len(reply) >= 2 and isinstance(reply[1], list):
        return [row for row in reply[1] if isinstance(row, list)]
    return []


class GraphIndex:
    """Read-only FalkorDB client that answers `is this episode stored?`."""

    def __init__(self, url: str = DEFAULT_REDIS_URL, *, client: object | None = None) -> None:
        self.url = url
        self._client = client

    def _redis(self) -> object:
        if self._client is None:
            import redis  # imported lazily so a test without redis still runs

            self._client = redis.Redis.from_url(
                self.url, socket_connect_timeout=SOCKET_TIMEOUT, socket_timeout=SOCKET_TIMEOUT
            )
        return self._client

    def _graph_names(self) -> set[str] | None:
        try:
            reply = self._redis().execute_command("GRAPH.LIST")
        except ImportError:
            return None
        except Exception:
            return None
        return {_text(name) for name in reply or []}

    def descriptions(self, group: str) -> set[str] | None:
        """Every episode description stored in `group`, or None when unreadable.

        `GRAPH.LIST` runs first because FalkorDB creates a graph on the first
        `GRAPH.QUERY` against it; an unknown graph must stay unknown instead of
        materializing on every presence check. An unknown graph is an empty
        group (nothing extracted there yet). Anything else (connection refused,
        auth, module missing) means the exact answer is unavailable and the
        caller must fall back.
        """
        names = self._graph_names()
        if names is None:
            return None
        if group not in names:
            return set()
        try:
            reply = self._redis().execute_command("GRAPH.QUERY", group, EPISODIC_QUERY)
        except Exception as exc:  # redis-py and FalkorDB raise their own types
            message = str(exc).lower()
            if any(marker in message for marker in _UNKNOWN_GRAPH):
                return set()
            return None
        return {_text(row[1]) for row in _rows(reply) if len(row) >= 2 and row[1] is not None}
