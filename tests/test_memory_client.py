from contextlib import asynccontextmanager
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).parents[1] / "modules/features/ai/memory/src"))

from memory_mcp import client  # noqa: E402
from memory_mcp.client import ClientConfig, UpstreamError  # noqa: E402


class OpenSessionTests(unittest.IsolatedAsyncioTestCase):
    async def test_redirects_are_disabled(self):
        captured = {}

        class FakeClient:
            def __init__(self, **kwargs):
                captured.update(kwargs)

            async def __aenter__(self):
                return self

            async def __aexit__(self, *args):
                return False

        @asynccontextmanager
        async def fake_stream(url, http_client=None):
            raise RuntimeError("stop before MCP")
            yield  # pragma: no cover

        with (
            mock.patch.object(client.httpx, "AsyncClient", FakeClient),
            mock.patch.object(client, "streamable_http_client", fake_stream),
            self.assertRaises(UpstreamError),
        ):
            async with client.open_session(ClientConfig(url="http://127.0.0.1:8182/mcp")):
                pass
        self.assertFalse(captured["follow_redirects"])


if __name__ == "__main__":
    unittest.main()
