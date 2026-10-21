"""Readiness gates for the local chat model and embedder.

Graphiti accepts an episode into an in-memory queue and can drop it if the
extraction model is unavailable, so the wrapper checks the model endpoints
before claiming a write succeeded. Reads only need the embedder.
"""

from __future__ import annotations

from dataclasses import dataclass

import httpx


class ReadinessError(RuntimeError):
    """One or more local model endpoints are unavailable."""


@dataclass(frozen=True)
class HealthProbes:
    llm_url: str
    embed_url: str
    timeout: float = 2.0

    async def _probe(self, client: httpx.AsyncClient, url: str) -> bool:
        try:
            response = await client.get(url)
        except httpx.HTTPError:
            return False
        return response.status_code == 200

    async def failures(self) -> list[str]:
        async with httpx.AsyncClient(timeout=self.timeout) as client:
            chat = await self._probe(client, f"{self.llm_url.rstrip('/')}/v1/models")
            embedder = await self._probe(client, f"{self.embed_url.rstrip('/')}/health")
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
        async with httpx.AsyncClient(timeout=self.timeout) as client:
            embedder = await self._probe(client, f"{self.embed_url.rstrip('/')}/health")
        if not embedder:
            raise ReadinessError(f"embedder unavailable at {self.embed_url} (memory search not attempted)")
