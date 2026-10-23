"""Direct FalkorDB access for presence checks and tombstone maintenance.

Graphiti exposes no queue status and no edge-invalidation tool, so the wrapper
reads episode presence straight from FalkorDB and holds one narrow Cypher write
path (tombstone maintenance). Every other graph access goes through Graphiti.

Graphiti stores each group in its own FalkorDB graph named after the group id.
An `Episodic` node carries `group_id`, `content`, and `created_at`; an
`EntityEdge` is a `RELATES_TO` relationship whose `episodes` property lists the
episode uuids that support it. The relationship type was verified read-only
against the live store (`MATCH ()-[r:RELATES_TO]->() RETURN type(r)`).
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone

DEFAULT_REDIS_URL = "redis://127.0.0.1:6379"
SOCKET_TIMEOUT = 5.0
RELATES_TO = "RELATES_TO"

# Every episode the same content produced, newest first. A revival re-extracts,
# so the old tombstoned episode and the new one both exist: presence must bind
# to the newest, and a tombstone must cover all of them.
EPISODIC_MATCHES_QUERY = (
    "MATCH (e:Episodic) WHERE e.group_id=$g AND e.content=$c "
    "RETURN e.uuid, e.created_at ORDER BY e.created_at DESC"
)
# Exclusive: this episode is the only support, so invalidate the edge.
_TOMBSTONE_EXCLUSIVE_QUERY = (
    f"MATCH (a)-[r:{RELATES_TO}]->(b) WHERE $ep IN r.episodes AND size(r.episodes) <= 1 "
    "SET r.invalid_at=$now RETURN count(r)"
)
# Shared: other episodes still support the fact, so only drop this episode.
_TOMBSTONE_SHARED_QUERY = (
    f"MATCH (a)-[r:{RELATES_TO}]->(b) WHERE $ep IN r.episodes AND size(r.episodes) > 1 "
    "SET r.episodes=[x IN r.episodes WHERE x <> $ep] RETURN count(r)"
)

# FalkorDB answers an unknown graph with an error; that is an empty group, not
# an unreachable database.
_UNKNOWN_GRAPH = ("invalid graph name", "no such graph", "graph not found")


class GraphUnavailable(RuntimeError):
    """The graph could not be read, so absence cannot be proven."""


@dataclass(frozen=True)
class EpisodeRef:
    uuid: str
    created_at: str


@dataclass(frozen=True)
class TombstoneResult:
    invalidated: int = 0
    shared: int = 0


def _text(value: object) -> str:
    """FalkorDB bulk strings arrive as bytes unless the client decodes them."""
    return value.decode("utf-8", "replace") if isinstance(value, bytes) else str(value)


def _rows(reply: object) -> list[list[object]]:
    """FalkorDB replies with `[header, rows, statistics]` for a RETURN query."""
    if isinstance(reply, list) and len(reply) >= 2 and isinstance(reply[1], list):
        return [row for row in reply[1] if isinstance(row, list)]
    return []


def moment(value: str | None) -> datetime | None:
    """Parse an ISO timestamp from either store, or None when unreadable.

    The graph writes `...+00:00` and the registry `...Z`, so the two are never
    compared as strings; both are parsed and compared as instants.
    """
    text = (value or "").strip()
    if not text:
        return None
    try:
        parsed = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed if parsed.tzinfo is not None else parsed.replace(tzinfo=timezone.utc)


def _not_older(ref: EpisodeRef, bound: datetime) -> bool:
    """Does the episode postdate (or coincide with) the bound?

    An unreadable graph timestamp cannot prove the episode came after the
    tombstone, so it is not treated as a revival match.
    """
    created = moment(ref.created_at)
    return created is not None and created >= bound


class GraphStore:
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
        except ImportError as exc:
            raise GraphUnavailable("redis client unavailable") from exc
        except Exception as exc:
            raise GraphUnavailable(str(exc)) from exc
        return {_text(name) for name in reply or []}
    def _query(self, group: str, query: str, params: dict[str, object]) -> list[list[object]]:
        try:
            reply = self._redis().execute_command(
                "GRAPH.QUERY", group, _parameterized(query, params)
            )
        except Exception as exc:
            message = str(exc).lower()
            if any(marker in message for marker in _UNKNOWN_GRAPH):
                return []
            raise GraphUnavailable(str(exc)) from exc
        return _rows(reply)

    def episode_for(
        self, group: str, content: str, *, since: str | None = None
    ) -> EpisodeRef | None:
        """The newest graph episode whose content matches exactly, or None.

        Newest, not oldest: a revived row re-extracts into a new episode, and
        reconciling must bind to that one rather than to the tombstoned
        episode that shares its content.

        `since` (a registry `created_at`) drops episodes older than that
        instant. A tombstone keeps its episode node on purpose, so without the
        bound a revived row would go active against the very episode it was
        revived from; the episode for this write is always newer.

        A missing FalkorDB graph is an empty group (nothing extracted yet), not
        an outage. GRAPH.LIST runs first so a presence check never materializes
        a graph for a group that has none.
        """
        notes = self.matches(group, content)
        bound = moment(since) if since is not None else None
        if bound is not None:
            notes = [note for note in notes if _not_older(note, bound)]
        return notes[0] if notes else None

    def matches(self, group: str, content: str) -> list[EpisodeRef]:
        """Every graph episode with this exact content, newest first."""
        names = self._graph_names()
        if names is None:
            raise GraphUnavailable("graph list unavailable")
        if group not in names:
            return []
        rows = self._query(group, EPISODIC_MATCHES_QUERY, {"g": group, "c": content})
        return [
            EpisodeRef(uuid=_text(row[0]), created_at=_text(row[1] if len(row) > 1 else ""))
            for row in rows
            if row and row[0] is not None
        ]

    def episode_uuids(self, group: str, content: str) -> list[str]:
        """Every graph episode uuid for this content, newest first."""
        return [note.uuid for note in self.matches(group, content)]

    def tombstone(self, group: str, episode_uuid: str, *, now: str) -> TombstoneResult:
        """Invalidate the episode's exclusive edges and detach it from shared ones."""
        names = self._graph_names()
        if names is None or group not in names:
            return TombstoneResult()
        exclusive = self._query(
            group, _TOMBSTONE_EXCLUSIVE_QUERY, {"ep": episode_uuid, "now": now}
        )
        shared = self._query(group, _TOMBSTONE_SHARED_QUERY, {"ep": episode_uuid})
        return TombstoneResult(invalidated=_count(exclusive), shared=_count(shared))


def _cypher_literal(value: object) -> str:
    """A Cypher string literal that preserves Unicode and escapes syntax.

    `--params` is not supported by the pinned FalkorDB build, so parameters are
    supplied with the `CYPHER name=value` prefix. JSON escapes Unicode as
    `\\uXXXX`, which that parser does not decode; escape only what is syntax.
    """
    text = str(value)
    escaped = (
        text.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\r", "\\r")
        .replace("\t", "\\t")
    )
    return f'"{escaped}"'


def _parameterized(query: str, params: dict[str, object]) -> str:
    if not params:
        return query
    prefix = " ".join(f"{name}={_cypher_literal(value)}" for name, value in params.items())
    return f"CYPHER {prefix} {query}"


def _count(rows: list[list[object]]) -> int:
    if not rows or not rows[0]:
        return 0
    try:
        return int(rows[0][0])  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return 0
