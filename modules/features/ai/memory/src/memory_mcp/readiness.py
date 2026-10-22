"""Readiness gates for the model endpoints Graphiti depends on.

Graphiti accepts an episode into an in-memory queue and can drop it if the
extraction model is unavailable, so the wrapper checks the model endpoints
before claiming a write succeeded. Reads only need the embedder.

Both endpoints default to the local services: extraction through the Neuralwatt
gateway on loopback and embeddings from llama.cpp. A remote embedder sets
`embed_model`, because the gateway has no llama.cpp `/health` to answer for it
and a real (tiny) embedding is the only honest probe.
"""

from __future__ import annotations

from dataclasses import dataclass

import httpx


class ReadinessError(RuntimeError):
    """One or more model endpoints are unavailable."""


@dataclass(frozen=True)
class HealthProbes:
    llm_url: str
    embed_url: str
    # The chat probe is a WAN round trip to Neuralwatt, not a loopback hop, so
    # the budget covers connect + response rather than one local socket write.
    timeout: float = 10.0
    # Set only for a remote embedder (model id sent with a one-word probe).
    embed_model: str | None = None
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
        """A llama.cpp `/health`, or one tiny embedding for a remote embedder."""
        url = self.embed_url.rstrip("/")
        if self.embed_model is None:
            return await self._probe(client, f"{url}/health")
        try:
            response = await client.post(
                f"{url}/v1/embeddings",
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
            failed.append(f"embedder unavailable at {self.embed_url}")
        return failed

    async def require_write(self) -> None:
        failed = await self.failures()
        if failed:
            raise ReadinessError("; ".join(failed) + " (memory write not queued)")

    async def require_search(self) -> None:
        async with self._client() as client:
            embedder = await self._embedder_ready(client)
        if not embedder:
            raise ReadinessError(f"embedder unavailable at {self.embed_url} (memory search not attempted)")
