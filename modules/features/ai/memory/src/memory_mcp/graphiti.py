"""Graphiti MCP backend adapter.

Only the tools the wrapper needs are exposed here. Delete and clear tools stay
out of the wrapper's surface entirely: tombstones are bookkeeping in the local
index, never a hard cascade in the graph.
"""

from __future__ import annotations

import json
from typing import Any

from .client import ClientConfig, UpstreamError, call_tool


class BackendError(RuntimeError):
    """Graphiti returned an error or an unparseable response."""


def _parse(text: str) -> Any:
    if not text:
        return {}
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return text


def _items(payload: Any, *keys: str) -> list[dict[str, Any]]:
    if isinstance(payload, list):
        return [item for item in payload if isinstance(item, dict)]
    if isinstance(payload, dict):
        for key in keys:
            value = payload.get(key)
            if isinstance(value, list):
                return [item for item in value if isinstance(item, dict)]
        for key in ("result", "items"):
            value = payload.get(key)
            if isinstance(value, list):
                return [item for item in value if isinstance(item, dict)]
    return []


class GraphitiBackend:
    def __init__(self, url: str, timeout: float = 20.0) -> None:
        self.url = url
        self.timeout = timeout

    async def _call(self, name: str, arguments: dict[str, object]) -> Any:
        config = ClientConfig(url=self.url, timeout=self.timeout)
        try:
            result = await call_tool(config, name, arguments)
        except UpstreamError as exc:
            raise BackendError(f"memory graph unreachable: {exc}") from exc
        if result.is_error:
            raise BackendError(result.text.strip() or f"{name} failed")
        payload = _parse(result.text)
        # Graphiti reports tool failures as a normal response with an `error`
        # field, not as MCP isError. Treat that as a failure instead of an
        # empty result or a successful queue.
        if isinstance(payload, dict) and payload.get("error"):
            raise BackendError(str(payload["error"]))
        return payload

    async def add_episode(
        self,
        *,
        name: str,
        episode_body: str,
        group_id: str,
        source_description: str,
        source: str = "text",
        reference_time: str | None = None,
    ) -> dict[str, Any]:
        # Deliberately no `uuid`: graphiti-core 0.31.2 treats a supplied uuid as
        # an existing episode lookup, so a new uuid fails in the queue worker
        # with "node <uuid> not found". The registry keeps the uuid5 identity
        # and records the graph's own uuid after reconciliation.
        arguments: dict[str, object] = {
            "name": name,
            "episode_body": episode_body,
            "group_id": group_id,
            "source": source,
            "source_description": source_description,
        }
        if reference_time:
            arguments["reference_time"] = reference_time
        payload = await self._call("add_memory", arguments)
        if isinstance(payload, dict):
            return payload
        return {"message": str(payload)}

    async def search_nodes(self, query: str, group_ids: list[str], max_nodes: int) -> list[dict[str, Any]]:
        payload = await self._call(
            "search_nodes",
            {"query": query, "group_ids": group_ids, "max_nodes": max_nodes},
        )
        return _items(payload, "nodes")

    async def search_facts(self, query: str, group_ids: list[str], max_facts: int) -> list[dict[str, Any]]:
        payload = await self._call(
            "search_memory_facts",
            {"query": query, "group_ids": group_ids, "max_facts": max_facts},
        )
        return _items(payload, "facts", "edges")

    async def get_episodes(self, group_ids: list[str], max_episodes: int) -> list[dict[str, Any]]:
        payload = await self._call(
            "get_episodes",
            {"group_ids": group_ids, "max_episodes": max_episodes},
        )
        return _items(payload, "episodes")

    async def get_status(self) -> dict[str, Any]:
        payload = await self._call("get_status", {})
        if isinstance(payload, dict):
            return payload
        return {"message": str(payload)}
