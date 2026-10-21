import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).parents[1] / "modules/features/ai/memory/src"))

from mcp.shared.memory import create_connected_server_and_client_session  # noqa: E402
from mcp.types import Tool  # noqa: E402

from memory_mcp import shim  # noqa: E402
from memory_mcp.client import ToolResult, UpstreamError  # noqa: E402
from memory_mcp.schema import FALLBACK_TOOLS, FALLBACK_TOOL_NAMES  # noqa: E402


class ShimProxyTests(unittest.IsolatedAsyncioTestCase):
    def config(self, **overrides):
        values = {"group": "owner--repo", "cwd": "/home/smores/code/example", "url": "http://127.0.0.1:8182/mcp"}
        values.update(overrides)
        return shim.ShimConfig(**values)

    def test_headers_carry_group_cwd_and_actor(self):
        headers = dict(self.config().client_config().headers)
        self.assertEqual(headers["X-Memory-Group"], "owner--repo")
        self.assertEqual(headers["X-Memory-Cwd"], "/home/smores/code/example")
        self.assertEqual(headers["X-Memory-Actor"], "maki")

    def test_no_tool_schema_accepts_a_group(self):
        for schema in FALLBACK_TOOLS:
            properties = schema["inputSchema"].get("properties", {})
            self.assertNotIn("group", properties)
            self.assertNotIn("group_id", properties)

    async def test_tools_list_is_proxied_with_headers(self):
        seen = []

        async def list_tools(config):
            seen.append(dict(config.headers))
            return [Tool(name="memory_write", description="store", inputSchema={"type": "object"})]

        server = shim.build_server(self.config(), list_tools_fn=list_tools)
        async with create_connected_server_and_client_session(server) as session:
            tools = await session.list_tools()
        self.assertEqual([tool.name for tool in tools.tools], ["memory_write"])
        self.assertEqual(seen[0]["X-Memory-Group"], "owner--repo")

    async def test_tools_list_falls_back_when_upstream_is_down(self):
        async def list_tools(_config):
            raise UpstreamError("Connection refused")

        server = shim.build_server(self.config(), list_tools_fn=list_tools)
        async with create_connected_server_and_client_session(server) as session:
            tools = await session.list_tools()
        self.assertEqual(tuple(tool.name for tool in tools.tools), FALLBACK_TOOL_NAMES)
        for tool in tools.tools:
            self.assertEqual(tool.inputSchema.get("type"), "object")

    async def test_tool_call_is_proxied(self):
        seen = []

        async def call_tool(config, name, arguments):
            seen.append((dict(config.headers), name, arguments))
            return ToolResult(text="stored ok", is_error=False)

        server = shim.build_server(self.config(), call_tool_fn=call_tool)
        async with create_connected_server_and_client_session(server) as session:
            result = await session.call_tool("memory_write", {"content": "x"})
        self.assertFalse(result.isError)
        self.assertEqual(result.content[0].text, "stored ok")
        self.assertEqual(seen[0][1], "memory_write")
        self.assertEqual(seen[0][2], {"content": "x"})
        self.assertEqual(seen[0][0]["X-Memory-Cwd"], "/home/smores/code/example")

    async def test_tool_error_from_upstream_is_preserved(self):
        async def call_tool(_config, _name, _arguments):
            return ToolResult(text="chat model unavailable", is_error=True)

        server = shim.build_server(self.config(), call_tool_fn=call_tool)
        async with create_connected_server_and_client_session(server) as session:
            result = await session.call_tool("memory_write", {"content": "x"})
        self.assertTrue(result.isError)
        self.assertIn("chat model unavailable", result.content[0].text)

    async def test_unreachable_server_is_a_clear_tool_error(self):
        async def call_tool(_config, _name, _arguments):
            raise UpstreamError("Connection refused")

        server = shim.build_server(self.config(), call_tool_fn=call_tool)
        async with create_connected_server_and_client_session(server) as session:
            result = await session.call_tool("memory_write", {"content": "x"})
        self.assertTrue(result.isError)
        self.assertIn("unreachable", result.content[0].text)
        self.assertIn("Connection refused", result.content[0].text)

    async def test_prompts_are_empty_when_upstream_is_down(self):
        async def list_prompts(_config):
            raise UpstreamError("Connection refused")

        server = shim.build_server(self.config(), list_prompts_fn=list_prompts)
        async with create_connected_server_and_client_session(server) as session:
            prompts = await session.list_prompts()
        self.assertEqual(prompts.prompts, [])


class ShimMainTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.env = {
            "PATH": os.environ["PATH"],
            "HOME": str(self.home),
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_SYSTEM": os.devnull,
        }

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, cwd, *args):
        subprocess.run(
            ["git", "-C", str(cwd), *args],
            capture_output=True,
            text=True,
            env=self.env,
            check=True,
        )

    def test_work_repo_is_refused_before_serving(self):
        repo = self.root / "work"
        repo.mkdir()
        self.git(repo, "init", "-q", "-b", "main")
        self.git(repo, "config", "smores.flow", "pr")
        self.git(repo, "remote", "add", "origin", "git@github.com:blitzy-org/service.git")
        with mock.patch.dict(os.environ, self.env, clear=True):
            self.assertEqual(shim.main(["--cwd", str(repo)]), 2)

    def test_personal_repo_builds_the_server_with_the_derived_group(self):
        repo = self.root / "personal"
        repo.mkdir()
        self.git(repo, "init", "-q", "-b", "main")
        self.git(repo, "remote", "add", "origin", "git@github.com:smores56/nix-config.git")
        captured = {}

        def build(config):
            captured["config"] = config
            return object()

        with (
            mock.patch.dict(os.environ, self.env, clear=True),
            mock.patch.object(shim, "build_server", build),
            mock.patch.object(shim.anyio, "run", lambda *args, **kwargs: None),
        ):
            self.assertEqual(shim.main(["--cwd", str(repo)]), 0)
        self.assertEqual(captured["config"].group, "smores56--nix-config")
        self.assertEqual(captured["config"].cwd, os.path.abspath(repo))


if __name__ == "__main__":
    unittest.main()
