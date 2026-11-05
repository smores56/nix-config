import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).parents[1] / "modules/features/ai/memory/src"))

from memory_mcp import cli  # noqa: E402
from memory_mcp.client import ToolResult, UpstreamError  # noqa: E402
from memory_mcp.groups import GroupRefused  # noqa: E402


class CliContextTests(unittest.TestCase):
    def parser(self):
        return cli.build_parser()

    def test_group_override_accepts_global(self):
        args = self.parser().parse_args(["--group", "global", "status"])
        group, cwd = cli.resolve_context(args)
        self.assertEqual(group, "global")
        self.assertTrue(cwd.startswith("/"))

    def test_group_override_refuses_work(self):
        args = self.parser().parse_args(["--group", "blitzy-org--repo", "status"])
        with self.assertRaises(GroupRefused):
            cli.resolve_context(args)

    def test_work_group_exits_two_with_a_message(self):
        stderr = io.StringIO()
        with redirect_stderr(stderr):
            code = cli.main(["--group", "work--repo", "status"])
        self.assertEqual(code, 2)
        self.assertIn("employer", stderr.getvalue())

    def test_cwd_is_derived_without_an_override(self):
        with tempfile.TemporaryDirectory() as directory:
            args = self.parser().parse_args(["--cwd", directory, "status"])
            group, cwd = cli.resolve_context(args)
        self.assertTrue(group.startswith("local--"))
        self.assertEqual(cwd, os.path.abspath(directory))


class CliOutputTests(unittest.TestCase):
    def setUp(self):
        self.token = tempfile.NamedTemporaryFile("w", delete=False)
        self.token.write("test-token")
        self.token.close()
        os.environ["MEMORY_MCP_TOKEN_FILE"] = self.token.name
        self.addCleanup(os.unlink, self.token.name)
        self.addCleanup(os.environ.pop, "MEMORY_MCP_TOKEN_FILE", None)

    def run_cli(self, argv, result):
        async def fake_call(_config, _tool, _arguments):
            return result

        stdout = io.StringIO()
        stderr = io.StringIO()
        with (
            mock.patch.object(cli, "call_tool", fake_call),
            redirect_stdout(stdout),
            redirect_stderr(stderr),
        ):
            code = cli.main(argv)
        return code, stdout.getvalue(), stderr.getvalue()

    def test_text_output(self):
        code, out, _err = self.run_cli(
            ["--group", "global", "status"],
            ToolResult(text="Memory status", is_error=False),
        )
        self.assertEqual(code, 0)
        self.assertEqual(out.strip(), "Memory status")

    def test_reindex_passes_scope_and_limit_to_the_tool(self):
        calls = []

        async def fake_call(_config, tool, arguments):
            calls.append((tool, arguments))
            return ToolResult(text="reindexed", is_error=False)

        with mock.patch.object(cli, "call_tool", fake_call), redirect_stdout(io.StringIO()):
            code = cli.main(["reindex", "--dry-run", "--limit", "7", "--all"])
        self.assertEqual(code, 0)
        self.assertEqual(
            calls,
            [("memory_reindex", {"everywhere": True, "dry_run": True, "force": False, "limit": 7})],
        )

    def test_search_passes_the_project_filter(self):
        calls = []

        async def fake_call(_config, tool, arguments):
            calls.append((tool, arguments))
            return ToolResult(text="results", is_error=False)

        with mock.patch.object(cli, "call_tool", fake_call), redirect_stdout(io.StringIO()):
            code = cli.main(["search", "falkordb", "--project", "owner--repo", "--limit", "3"])
        self.assertEqual(code, 0)
        self.assertEqual(
            calls,
            [("memory_search", {"query": "falkordb", "limit": 3, "project": "owner--repo"})],
        )

    def test_reindex_refuses_group_with_all(self):
        stderr = io.StringIO()
        with redirect_stderr(stderr):
            code = cli.main(["--group", "owner--repo", "reindex", "--all"])
        self.assertEqual(code, 2)
        self.assertIn("exclusive", stderr.getvalue())

    def test_json_output(self):
        code, out, _err = self.run_cli(
            ["--group", "global", "--json", "search", "anything"],
            ToolResult(text="results", is_error=False, structured={"nodes": []}),
        )
        self.assertEqual(code, 0)
        payload = json.loads(out)
        self.assertEqual(payload["tool"], "memory_search")
        self.assertEqual(payload["group"], "global")
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["text"], "results")
        self.assertEqual(payload["structured"], {"nodes": []})

    def test_tool_error_sets_exit_one(self):
        code, out, _err = self.run_cli(
            ["--group", "global", "search", "anything"],
            ToolResult(text="embedder unavailable", is_error=True),
        )
        self.assertEqual(code, 1)
        self.assertIn("embedder unavailable", out)

    def test_write_reads_stdin(self):
        seen = []

        async def fake_call(_config, tool, arguments):
            seen.append((tool, arguments))
            return ToolResult(text="stored", is_error=False)

        stdout = io.StringIO()
        with (
            mock.patch.object(cli, "call_tool", fake_call),
            mock.patch.object(sys, "stdin", io.StringIO("from stdin\n")),
            redirect_stdout(stdout),
        ):
            code = cli.main(["--group", "global", "write", "-"])
        self.assertEqual(code, 0)
        self.assertEqual(seen[0], ("memory_write", {"content": "from stdin\n"}))

    def test_unreachable_server_is_exit_one(self):
        async def fake_call(_config, _tool, _arguments):
            raise UpstreamError("Connection refused")

        stderr = io.StringIO()
        with mock.patch.object(cli, "call_tool", fake_call), redirect_stderr(stderr):
            code = cli.main(["--group", "global", "status"])
        self.assertEqual(code, 1)
        self.assertIn("server unreachable", stderr.getvalue())

    def test_get_and_retry_map_to_the_matching_tools(self):
        seen = []

        async def fake_call(_config, tool, arguments):
            seen.append((tool, arguments))
            return ToolResult(text="ok", is_error=False)

        with mock.patch.object(cli, "call_tool", fake_call), redirect_stdout(io.StringIO()):
            self.assertEqual(cli.main(["--group", "global", "get", "ref-1"]), 0)
            self.assertEqual(cli.main(["--group", "global", "retry", "ref-2"]), 0)
        self.assertEqual(seen, [("memory_get", {"ref": "ref-1"}), ("memory_retry", {"ref": "ref-2"})])


if __name__ == "__main__":
    unittest.main()
