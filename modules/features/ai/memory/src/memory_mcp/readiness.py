"""Readiness gates for search and reconciler retries.

Writes are never gated: the registry accepts content offline and the graph is
filled in when the extraction endpoint returns. The reconciler uses `failures`
to pause retries while either model endpoint is down, and search still needs
the embedder.

Extraction and embeddings both go through the instance's LLM gateway on loopback,
which has no `/health` of its own for the embedder, so a real (tiny) embedding
is the only honest probe.
"""

from __future__ import annotations

from dataclasses import dataclass

import httpx


class ReadinessError(RuntimeError):
    """One or more model endpoints are unavailable."""


@dataclass(frozen=True)
class HealthProbes:
    llm_url: str
    # Graphiti's embedding model (`MEMORY_EMBED_MODEL`, set once per instance).
    embed_model: str
    # The chat probe is a WAN round trip to the model provider, not a loopback hop, so
    # the budget covers connect + response rather than one local socket write.
    timeout: float = 10.0
    # Test seam; production talks to real endpoints.
    transport: httpx.AsyncBaseTransport | None = None

    def _client(self) -> httpx.AsyncClient:
        return httpx.AsyncClient(timeout=self.timeout, transport=self.transport)

    async def _probe(self, client: httpx.AsyncClient, url: str) -> bool:
        try:
            response = await client.get(url)
        except httpx.HTTPError:
            return False
        return response.status_code == 200

    async def _embedder_ready(self, client: httpx.AsyncClient) -> bool:
        try:
            response = await client.post(
                f"{self.llm_url.rstrip('/')}/v1/embeddings",
                json={"input": "ready", "model": self.embed_model},
            )
        except httpx.HTTPError:
            return False
        return response.status_code == 200

    async def failures(self) -> list[str]:
        async with self._client() as client:
            chat = await self._probe(client, f"{self.llm_url.rstrip('/')}/v1/models")
            embedder = await self._embedder_ready(client)
        failed: list[str] = []
        if not chat:
            failed.append(f"chat model unavailable at {self.llm_url}")
        if not embedder:
            failed.append(f"embedder unavailable at {self.llm_url}")
        return failed

    async def require_search(self) -> None:
        async with self._client() as client:
            embedder = await self._embedder_ready(client)
        if not embedder:
            raise ReadinessError(f"embedder unavailable at {self.llm_url} (memory search not attempted)")
