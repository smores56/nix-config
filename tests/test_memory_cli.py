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


class CliIngestTests(unittest.TestCase):
    def test_ingest_flags_parse(self):
        args = cli.build_parser().parse_args(
            [
                "--url",
                "http://wrapper/mcp",
                "ingest",
                "all",
                "--limit",
                "10",
                "--dry-run",
                "--batch",
                "2",
                "--timeout",
                "60",
                "--repair",
                "--force",
                "--reset-state",
                "--notes-dir",
                "/notes",
                "--docs-root",
                "/docs",
                "--repo",
                "kanbei",
                "--repo-list",
                "/repos.txt",
                "--state",
                "/state.json",
                "--report",
                "/report.json",
                "--redis-url",
                "redis://127.0.0.1:6399",
                "--verbose",
            ]
        )
        self.assertEqual(args.command, "ingest")
        self.assertEqual(args.source, "all")
        self.assertEqual(args.batch, 2)
        self.assertEqual(args.repo, ["kanbei"])
        self.assertEqual(args.redis_url, "redis://127.0.0.1:6399")
        self.assertTrue(args.repair and args.force and args.reset_state)
        self.assertTrue(args.dry_run and args.verbose)

    def test_ingest_defaults_are_conservative(self):
        args = cli.build_parser().parse_args(["ingest", "sdlc"])
        self.assertEqual(args.batch, 1)
        self.assertEqual(args.timeout, 600.0)
        self.assertFalse(args.repair)
        self.assertIsNone(args.docs_root)

    def test_group_is_rejected_with_ingest(self):
        async def fake_ingest(_args):
            raise AssertionError("ingest must not run with --group")

        stderr = io.StringIO()
        with mock.patch.object(cli, "run_ingest", fake_ingest), redirect_stderr(stderr):
            code = cli.main(["--group", "global", "ingest", "notes", "--dry-run"])
        self.assertEqual(code, 2)
        self.assertIn("--group is not valid with ingest", stderr.getvalue())

    def test_ingest_failure_is_exit_one(self):
        from memory_mcp.ingest_runner import IngestError

        async def fake_ingest(_args):
            raise IngestError("raw Graphiti is unreachable")

        stderr = io.StringIO()
        with mock.patch.object(cli, "run_ingest", fake_ingest), redirect_stderr(stderr):
            code = cli.main(["ingest", "sdlc"])
        self.assertEqual(code, 1)
        self.assertIn("raw Graphiti", stderr.getvalue())

    def test_json_dry_run_emits_only_json_to_stdout(self):
        from memory_mcp.ingest_sources import Episode, Plan

        plans = [
            Plan(
                source="notes",
                episodes=[Episode(source="notes", source_id="note:a.md#body", group="global", content="a " * 40)],
            )
        ]
        with tempfile.TemporaryDirectory() as directory:
            stdout = io.StringIO()
            stderr = io.StringIO()
            with (
                mock.patch.object(cli, "build_plans", return_value=(plans, {})),
                redirect_stdout(stdout),
                redirect_stderr(stderr),
            ):
                code = cli.main(
                    [
                        "--json",
                        "ingest",
                        "notes",
                        "--dry-run",
                        "--state",
                        str(Path(directory, "state.json")),
                        "--report",
                        str(Path(directory, "report.json")),
                    ]
                )
        self.assertEqual(code, 0)
        payload = json.loads(stdout.getvalue())
        self.assertTrue(payload["dry_run"])
        self.assertEqual(payload["totals"]["built"], 1)
        self.assertNotIn("ingest plan", stdout.getvalue())
        self.assertIn("ingest plan (dry run)", stderr.getvalue())

    def test_all_reports_a_failed_source_and_runs_the_rest(self):
        from memory_mcp import ingest_sources
        from memory_mcp.ingest_sources import Episode, Plan

        def failing_issues():
            raise ingest_sources.SourceError("gh is not installed")

        notes = Plan(
            source="notes",
            episodes=[Episode(source="notes", source_id="note:a.md#body", group="global", content="a " * 40)],
        )
        with tempfile.TemporaryDirectory() as directory:
            stdout = io.StringIO()
            with (
                mock.patch.object(ingest_sources, "fetch_issues", failing_issues),
                mock.patch.object(ingest_sources, "notes_plan", lambda _dir: notes),
                mock.patch.object(ingest_sources, "docs_plan", lambda *_a, **_k: Plan(source="docs")),
                redirect_stdout(stdout),
                redirect_stderr(io.StringIO()),
            ):
                code = cli.main(
                    [
                        "--json",
                        "ingest",
                        "all",
                        "--dry-run",
                        "--state",
                        str(Path(directory, "state.json")),
                        "--report",
                        str(Path(directory, "report.json")),
                    ]
                )
        self.assertEqual(code, 1)
        payload = json.loads(stdout.getvalue())
        self.assertEqual(payload["sources"]["sdlc"]["error"], "gh is not installed")
        self.assertEqual(payload["sources"]["notes"]["totals"]["built"], 1)
        self.assertEqual(payload["failures"][0]["source_id"], "*")


if __name__ == "__main__":
    unittest.main()
