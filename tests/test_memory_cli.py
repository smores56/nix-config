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

    def test_get_and_retry_map_to_the_matching_tools(self):
        seen = []

        async def fake_call(_config, tool, arguments):
            seen.append((tool, arguments))
            return ToolResult(text="ok", is_error=False)

        with mock.patch.object(cli, "call_tool", fake_call), redirect_stdout(io.StringIO()):
            self.assertEqual(cli.main(["--group", "global", "get", "ref-1"]), 0)
            self.assertEqual(cli.main(["--group", "global", "retry", "ref-2"]), 0)
        self.assertEqual(seen, [("memory_get", {"ref": "ref-1"}), ("memory_retry", {"ref": "ref-2"})])


class CliIngestTests(unittest.TestCase):
    def test_sessions_flags_parse_with_a_default_sample(self):
        args = cli.build_parser().parse_args(["ingest", "sessions"])
        self.assertEqual(args.session_limit, 50)
        self.assertEqual(args.session_concurrency, 3)
        self.assertIsNone(args.sessions_dir)
        self.assertEqual(cli.DEFAULT_SESSION_SAMPLE, 50)

    def test_sessions_dry_run_reports_without_building_a_model_client(self):
        from memory_mcp import session_summary

        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "s-1.jsonl").write_text(
                "\n".join(
                    [
                        json.dumps(
                            {
                                "t": "header",
                                "v": 2,
                                "id": "s-1",
                                "model": "m",
                                "cwd": directory,
                                "created_at": 1760000000,
                            }
                        ),
                        json.dumps(
                            {"t": "msg", "d": {"role": "user", "content": [{"type": "text", "text": "hello there"}]}}
                        ),
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            stdout = io.StringIO()
            with (
                mock.patch.object(
                    session_summary,
                    "SummaryClient",
                    side_effect=AssertionError("a dry run must not build the gateway client"),
                ),
                redirect_stdout(stdout),
                redirect_stderr(io.StringIO()),
            ):
                code = cli.main(
                    [
                        "--json",
                        "ingest",
                        "sessions",
                        "--dry-run",
                        "--sessions-dir",
                        directory,
                        "--report",
                        str(Path(directory, "report.json")),
                    ]
                )
            self.assertFalse(Path(directory, "report.json").exists())
            self.assertEqual(code, 0)
            payload = json.loads(stdout.getvalue())
            self.assertTrue(payload["sessions"]["dry_run"])
            self.assertEqual(payload["sessions"]["sampled"], 1)
            self.assertEqual(payload["sessions"]["parsed"], 1)
            self.assertGreater(payload["sessions"]["estimated_prompt_tokens"], 0)
            self.assertNotIn("sessions", payload["source_errors"])

    def test_all_includes_sessions_by_default(self):
        from memory_mcp import cli as cli_module
        from memory_mcp import ingest_sources
        from memory_mcp.ingest_sources import Episode, Plan
        from memory_mcp.sessions import SessionPlanResult

        sessions_plan = Plan(
            source="sessions",
            episodes=[
                Episode(
                    source="session",
                    source_id="s-1",
                    group="global",
                    content="a session summary worth storing",
                    tags=("session", "s-1"),
                )
            ],
        )
        report = {"sampled": 1, "items": [], "dry_run": True}

        async def fake_sessions(_args):
            return SessionPlanResult(plan=sessions_plan, report=report)

        with tempfile.TemporaryDirectory() as directory:
            stdout = io.StringIO()
            stderr = io.StringIO()
            with (
                mock.patch.object(ingest_sources, "fetch_issues", lambda: []),
                mock.patch.object(ingest_sources, "notes_plan", lambda _dir: Plan(source="notes")),
                mock.patch.object(ingest_sources, "docs_plan", lambda *_a, **_k: Plan(source="docs")),
                mock.patch.object(cli_module, "build_sessions", fake_sessions),
                redirect_stdout(stdout),
                redirect_stderr(stderr),
            ):
                code = cli.main(
                    [
                        "--json",
                        "ingest",
                        "all",
                        "--dry-run",
                        "--report",
                        str(Path(directory, "report.json")),
                    ]
                )
        self.assertEqual(code, 0)
        payload = json.loads(stdout.getvalue())
        self.assertEqual(payload["totals"]["built"], 1)
        self.assertEqual(payload["sessions"]["sampled"], 1)
        self.assertIn("sessions: 1 sampled", stderr.getvalue())

    def test_a_broken_sessions_source_fails_a_single_source_run(self):
        from memory_mcp import cli as cli_module
        from memory_mcp.sessions import SessionError

        async def failing(_args):
            raise SessionError("sessions directory not found: /nope")

        stderr = io.StringIO()
        with (
            mock.patch.object(cli_module, "build_sessions", failing),
            redirect_stderr(stderr),
        ):
            code = cli.main(["ingest", "sessions", "--dry-run"])
        self.assertEqual(code, 1)
        self.assertIn("sessions directory not found", stderr.getvalue())

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
                "--concurrency",
                "2",
                "--timeout",
                "60",
                "--notes-dir",
                "/notes",
                "--docs-root",
                "/docs",
                "--repo",
                "kanbei",
                "--repo-list",
                "/repos.txt",
                "--report",
                "/report.json",
                "--verbose",
            ]
        )
        self.assertEqual(args.command, "ingest")
        self.assertEqual(args.source, "all")
        self.assertEqual(args.concurrency, 2)
        self.assertEqual(args.repo, ["kanbei"])
        self.assertEqual(cli.internal_url(args.url), "http://wrapper")
        self.assertTrue(args.dry_run and args.verbose)

    def test_ingest_defaults_are_conservative(self):
        args = cli.build_parser().parse_args(["ingest", "sdlc"])
        self.assertEqual(args.concurrency, 4)
        self.assertEqual(args.timeout, 60.0)
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
            raise IngestError("wrapper unreachable")

        stderr = io.StringIO()
        with mock.patch.object(cli, "run_ingest", fake_ingest), redirect_stderr(stderr):
            code = cli.main(["ingest", "sdlc"])
        self.assertEqual(code, 1)
        self.assertIn("wrapper unreachable", stderr.getvalue())

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
                        "--report",
                        str(Path(directory, "report.json")),
                    ]
                )
        self.assertEqual(code, 1)
        payload = json.loads(stdout.getvalue())
        self.assertEqual(payload["source_errors"]["sdlc"], "gh is not installed")
        self.assertEqual(payload["totals"]["built"], 1)
        self.assertEqual(payload["failures"][0]["source_id"], "*")


if __name__ == "__main__":
    unittest.main()
