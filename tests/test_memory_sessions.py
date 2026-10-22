"""Maki session ingest: parsing, budgeting, summarization, episodes, report."""

import asyncio
import json
import math
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).parents[1] / "modules/features/ai/memory/src"))

import httpx  # noqa: E402

from memory_mcp import session_summary as summary  # noqa: E402
from memory_mcp import sessions  # noqa: E402
from memory_mcp.groups import GroupRefused  # noqa: E402
from memory_mcp.ingest_sources import Episode, Plan  # noqa: E402
from memory_mcp.ingest_runner import IngestRunner, RunnerConfig  # noqa: E402
from memory_mcp.normalize import content_hash, normalize_content  # noqa: E402


def header(session_id, *, cwd="/tmp/scratch", created_at=1760000000, model="neuralwatt/x", version=2):
    return {
        "t": "header",
        "v": version,
        "id": session_id,
        "model": model,
        "cwd": cwd,
        "created_at": created_at,
    }


def msg(role, *parts):
    return {"t": "msg", "d": {"role": role, "content": list(parts)}}


def text(value):
    return {"type": "text", "text": value}


THINKING = {"type": "thinking", "thinking": "secret chain of thought"}
TOOL = {"type": "tool_use", "id": "tool-1", "name": "bash", "input": {"command": "ls"}}


def write_session(directory, session_id, records, *, tail="", mtime=None):
    path = Path(directory) / f"{session_id}.jsonl"
    body = "\n".join(json.dumps(record) for record in records) + "\n" + tail
    path.write_text(body, encoding="utf-8")
    if mtime is not None:
        os.utime(path, (mtime, mtime))
    return path


def plain_session(session_id="s-1", **kwargs):
    return [
        header(session_id, **kwargs),
        msg("user", text("Add a cowsay package to the repo.")),
        msg("assistant", text("I added cowsay and ran nix fmt.")),
    ]


def extraction(**overrides):
    return summary.Extraction(
        summary=overrides.get(
            "summary",
            "The user asked for cowsay to be added to the package list. "
            "The assistant edited modules/features/packages.nix and ran nix fmt. "
            "Nothing was left open.",
        ),
        decisions=overrides.get("decisions", (summary.SummaryItem("Add cowsay", "cowsay was added to packages.nix."),)),
        constraints=overrides.get("constraints", ()),
        errors=overrides.get("errors", ()),
        preferences=overrides.get("preferences", ()),
    )


def result(parsed=None, *, prompt_tokens=1000, completion_tokens=400, attempts=1, wall_seconds=1.5):
    return summary.SummaryResult(
        extraction=parsed or extraction(),
        prompt_tokens=prompt_tokens,
        completion_tokens=completion_tokens,
        attempts=attempts,
        wall_seconds=wall_seconds,
        model="deepseek-v4.1-flash",
    )


class SessionParseTests(unittest.TestCase):
    def test_keeps_text_drops_thinking_and_tool_noise(self):
        with tempfile.TemporaryDirectory() as directory:
            path = write_session(
                directory,
                "abc",
                [
                    header("abc", cwd="/tmp/scratch", created_at=1760000000),
                    msg("system", text("You are a helpful agent.")),
                    msg("user", text("Explain the plan."), THINKING),
                    msg("assistant", text("Here is the plan."), THINKING, TOOL),
                    {"t": "meta", "title": "Plan talk", "updated_at": 1760000500},
                ],
            )
            session = sessions.parse_session(path)
        self.assertEqual(session.id, "abc")
        self.assertEqual(session.title, "Plan talk")
        self.assertEqual(session.updated_at, 1760000500)
        self.assertEqual(
            [(message.role, message.text) for message in session.messages],
            [("user", "Explain the plan."), ("assistant", "Here is the plan.")],
        )
        self.assertEqual(session.valid_at, "2025-10-09T08:53:20Z")

    def test_a_truncated_tail_is_tolerated(self):
        with tempfile.TemporaryDirectory() as directory:
            path = write_session(
                directory,
                "trunc",
                plain_session("trunc"),
                tail='{"t":"msg","d":{"role":"assistant","content":[{"ty',
            )
            session = sessions.parse_session(path)
        self.assertEqual(session.dropped_lines, 1)
        self.assertEqual(len(session.messages), 2)

    def test_missing_or_bad_header_is_an_error(self):
        with tempfile.TemporaryDirectory() as directory:
            empty = Path(directory, "empty.jsonl")
            empty.write_text("", encoding="utf-8")
            with self.assertRaises(sessions.SessionError):
                sessions.parse_session(empty)
            no_cwd = write_session(directory, "bad", [{"t": "header", "v": 2, "id": "x"}])
            with self.assertRaises(sessions.SessionError):
                sessions.parse_session(no_cwd)
            future = write_session(directory, "v3", [header("v3", version=3)])
            with self.assertRaises(sessions.SessionError):
                sessions.parse_session(future)

    def test_unreadable_file_is_an_error_not_a_crash(self):
        with self.assertRaises(sessions.SessionError):
            sessions.parse_session(Path("/nonexistent/session.jsonl"))

    def test_valid_at_falls_back_to_the_file_mtime(self):
        with tempfile.TemporaryDirectory() as directory:
            record = header("no-date", created_at=None)
            path = write_session(directory, "no-date", [record], mtime=1760000000)
            session = sessions.parse_session(path)
        self.assertEqual(session.created_at, 1760000000)
        self.assertTrue(session.valid_at.startswith("2025-10-09T"))


class BudgetTests(unittest.TestCase):
    def message(self, role, size, marker):
        return sessions.Message(role=role, text=marker + "x" * size)

    def test_a_huge_session_is_bounded_and_keeps_first_and_last(self):
        messages = [self.message("user", 2000, f"m{index}-") for index in range(200)]
        transcript, omitted = sessions.bounded_transcript(messages)
        self.assertLessEqual(len(transcript), sessions.MAX_TRANSCRIPT_CHARS)
        self.assertIn("m0-", transcript)
        self.assertIn("m199-", transcript)
        self.assertGreater(omitted, 0)
        self.assertIn("omitted", transcript)

    def test_long_messages_are_truncated_and_middle_dropped(self):
        messages = [self.message("assistant", sessions.MAX_MESSAGE_CHARS + 500, f"m{index}-") for index in range(60)]
        transcript, omitted = sessions.bounded_transcript(messages)
        self.assertLessEqual(len(transcript), sessions.MAX_TRANSCRIPT_CHARS)
        self.assertGreater(omitted, 0)
        self.assertNotIn("x" * (sessions.MAX_MESSAGE_CHARS + 100), transcript)

    def test_small_session_is_kept_whole(self):
        messages = [self.message("user", 10, "hi"), self.message("assistant", 10, "hello")]
        transcript, omitted = sessions.bounded_transcript(messages)
        self.assertEqual(omitted, 0)
        self.assertIn("User: hi", transcript)
        self.assertIn("Assistant: hello", transcript)


class GroupTests(unittest.TestCase):
    def test_non_repo_cwd_becomes_a_local_group(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory, "scratch-area")
            root.mkdir()
            self.assertEqual(sessions.session_group(str(root)), "local--scratch-area")

    def test_personal_repo_cwd_becomes_owner_repo(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory, "kanbei")
            root.mkdir()
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            subprocess.run(
                ["git", "-C", str(root), "remote", "add", "origin", "git@github.com:smores56/kanbei.git"],
                check=True,
            )
            self.assertEqual(sessions.session_group(str(root)), "smores56--kanbei")

    def test_work_repo_cwd_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory, "checkout")
            root.mkdir()
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            subprocess.run(
                ["git", "-C", str(root), "remote", "add", "origin", "git@github.com:blitzy-ai/service.git"],
                check=True,
            )
            with self.assertRaises(GroupRefused):
                sessions.session_group(str(root))

    def test_work_path_component_is_refused_even_when_missing(self):
        with self.assertRaises(GroupRefused):
            sessions.session_group("/home/smores/code/github.com/blitzy-ai/service")

    def test_missing_personal_path_falls_back_to_local(self):
        self.assertEqual(
            sessions.session_group("/home/smores/code/github.com/smores56/missing-repo"),
            "local--missing-repo",
        )


class SelectionTests(unittest.TestCase):
    def test_most_recent_sessions_come_first_and_are_limited(self):
        with tempfile.TemporaryDirectory() as directory:
            for index in range(3):
                write_session(directory, f"s{index}", plain_session(f"s{index}"), mtime=1760000000 + index)
            picked = sessions.sample_session_files(directory, 2)
            self.assertEqual([path.stem for path in picked], ["s2", "s1"])

    def test_a_missing_explicit_directory_fails_loudly(self):
        with self.assertRaises(sessions.SessionError):
            sessions.sample_session_files("/nonexistent/maki/sessions", 5)

    def test_session_dirs_follow_the_environment(self):
        with mock.patch.dict(os.environ, {"MAKI_SESSIONS_DIR": "/tmp/explicit"}, clear=False):
            self.assertEqual(sessions.sessions_dirs(), [Path("/tmp/explicit")])
        with mock.patch.dict(os.environ, {"XDG_STATE_HOME": "/tmp/state"}, clear=False):
            os.environ.pop("MAKI_SESSIONS_DIR", None)
            self.assertEqual(sessions.sessions_dirs()[0], Path("/tmp/state/maki/sessions"))


def chat_response(payload, *, usage=None, status=200, content=None):
    body = {
        "choices": [{"message": {"content": content if content is not None else json.dumps(payload)}}],
        "usage": usage if usage is not None else {"prompt_tokens": 1200, "completion_tokens": 300},
    }
    return httpx.Response(status, json=body)


VALID_PAYLOAD = {
    "summary": "The user asked for a session summary. " * 10,
    "decisions": [{"heading": "Use uv", "detail": "uv replaced pip for the CLI."}],
    "constraints": ["Never run sudo"],
    "errors": [{"heading": "nix fmt failed", "detail": "A stale lock file broke it; deleting it fixed the run."}],
    "preferences": [],
}


class SummaryClientTests(unittest.IsolatedAsyncioTestCase):
    async def call(self, handler, transcript="User: do the thing", **kwargs):
        transport = httpx.MockTransport(handler)
        async with summary.SummaryClient(transport=transport, **kwargs) as client:
            return await client.summarize(transcript)

    async def test_request_shape_and_usage_accounting(self):
        calls = []

        def handler(request):
            calls.append(json.loads(request.read()))
            return chat_response(VALID_PAYLOAD)

        result = await self.call(handler)
        self.assertEqual(len(calls), 1)
        body = calls[0]
        self.assertEqual(body["model"], "deepseek-v4.1-flash")
        self.assertEqual(body["temperature"], 0)
        self.assertEqual(body["response_format"], {"type": "json_object"})
        self.assertIn("do the thing", body["messages"][-1]["content"])
        self.assertEqual(result.prompt_tokens, 1200)
        self.assertEqual(result.completion_tokens, 300)
        self.assertEqual(len(result.extraction.decisions), 1)
        self.assertEqual(len(result.extraction.constraints), 1)
        self.assertEqual(result.extraction.constraints[0].heading, "Never run sudo")

    async def test_a_fenced_malformed_first_answer_is_retried_once(self):
        calls = []

        def handler(request):
            calls.append(request)
            if len(calls) == 1:
                return chat_response(None, content="Sure! Here is your json:")
            return chat_response(None, content="```json\n" + json.dumps(VALID_PAYLOAD) + "\n```")

        result = await self.call(handler)
        self.assertEqual(len(calls), 2)
        self.assertEqual(result.attempts, 2)

    async def test_two_malformed_answers_fail_the_session(self):
        def handler(_request):
            return chat_response(None, content="not json at all")

        with self.assertRaises(summary.SummaryError):
            await self.call(handler)

    async def test_a_server_error_is_retried_and_a_client_error_is_not(self):
        calls = []

        def flaky(request):
            calls.append(request)
            if len(calls) == 1:
                return httpx.Response(503, json={"error": {"message": "boom"}})
            return chat_response(VALID_PAYLOAD)

        await self.call(flaky)
        self.assertEqual(len(calls), 2)

        calls.clear()

        def rejected(request):
            calls.append(request)
            return httpx.Response(400, json={"error": {"message": "bad request"}})

        with self.assertRaises(summary.SummaryError):
            await self.call(rejected)
        self.assertEqual(len(calls), 1)

    async def test_missing_usage_is_zero_not_an_error(self):
        def handler(_request):
            return httpx.Response(200, json={"choices": [{"message": {"content": json.dumps(VALID_PAYLOAD)}}]})

        result = await self.call(handler)
        self.assertEqual((result.prompt_tokens, result.completion_tokens), (0, 0))

    async def test_cost_uses_per_million_prices(self):
        self.assertAlmostEqual(summary.cost_usd(1_000_000, 0, 0.15, 0.60), 0.15)
        self.assertAlmostEqual(summary.cost_usd(0, 1_000_000, 0.15, 0.60), 0.60)
        self.assertAlmostEqual(summary.cost_usd(1200, 300, 0.15, 0.60), 0.00018 + 0.00018)

    async def test_parse_summary_rejects_a_missing_or_tiny_summary(self):
        for payload in ({}, {"summary": "ok"}, {"summary": 12}):
            with self.assertRaises(summary.SummaryError):
                summary.parse_summary(json.dumps(payload))

    async def test_parse_summary_accepts_plain_string_items_and_caps_them(self):
        payload = {
            "summary": "A summary long enough to be believable. " * 5,
            "decisions": [f"decision {index}" for index in range(20)],
            "errors": [{"detail": "detail without a heading"}],
        }
        parsed = summary.parse_summary(json.dumps(payload))
        self.assertEqual(len(parsed.decisions), summary.MAX_ITEMS_PER_CATEGORY)
        self.assertTrue(parsed.decisions[0].heading.startswith("decision 0"))
        self.assertTrue(parsed.errors[0].heading)


class EpisodeTests(unittest.TestCase):
    def session(self, **kwargs):
        with tempfile.TemporaryDirectory() as directory:
            path = write_session(directory, "sess-9", plain_session("sess-9", **kwargs))
            return sessions.parse_session(path)

    def test_summary_and_each_item_become_episodes(self):
        session = self.session()
        parsed = extraction(
            constraints=(summary.SummaryItem("No sudo", "The user forbids sudo."),),
            preferences=(summary.SummaryItem("Terse replies", "Prefer terse replies."),),
        )
        episodes = sessions.episodes_for(session, "local--scratch", parsed)
        self.assertEqual(len(episodes), 4)
        self.assertTrue(all(episode.source == "session" for episode in episodes))
        self.assertTrue(all(episode.source_id == "sess-9" for episode in episodes))
        self.assertTrue(all(episode.kind == "text" for episode in episodes))
        self.assertTrue(all(episode.valid_at == session.valid_at for episode in episodes))
        self.assertIn("session", episodes[0].tags)
        self.assertIn("sess-9", episodes[0].tags)
        self.assertIn(parsed.summary.split(".")[0], episodes[0].content)
        self.assertIn("constraint: No sudo", episodes[2].content)
        self.assertIn("preference: Terse replies", episodes[3].content)

    def test_an_empty_extraction_still_yields_the_summary(self):
        session = self.session()
        episodes = sessions.episodes_for(
            session,
            "local--scratch",
            extraction(decisions=(), constraints=(), errors=(), preferences=()),
        )
        self.assertEqual(len(episodes), 1)
        self.assertTrue(episodes[0].content.startswith("[maki:sess-9]"))


class BuildPlanTests(unittest.IsolatedAsyncioTestCase):
    def directory(self, records=None, session_id="s-1"):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        write_session(self.tmp.name, session_id, records or plain_session(session_id))
        return self.tmp.name

    async def test_plan_surfaces_per_session_metrics_and_cost(self):
        directory = self.directory()
        calls = []

        async def fake_summarize(transcript):
            calls.append(transcript)
            return result(prompt_tokens=2000, completion_tokens=800, wall_seconds=2.5)

        built = await sessions.build_session_plan(
            sessions_dir=directory,
            summarizer=fake_summarize,
            prices=summary.Prices(input_per_million=0.15, output_per_million=0.60),
        )
        self.assertEqual(len(calls), 1)
        report = built.report
        self.assertEqual(report["sampled"], 1)
        self.assertEqual(report["summarized"], 1)
        self.assertEqual(report["prompt_tokens"], 2000)
        self.assertEqual(report["completion_tokens"], 800)
        self.assertAlmostEqual(report["cost_usd"], 0.0003 + 0.00048)
        self.assertEqual(report["model"], "deepseek-v4.1-flash")
        item = report["items"][0]
        self.assertEqual(item["session_id"], "s-1")
        self.assertEqual(item["group"], "local--scratch")
        self.assertEqual(item["wall_seconds"], 2.5)
        self.assertEqual(item["episodes"], 2)
        self.assertEqual(len(built.plan.episodes), 2)
        self.assertEqual(built.plan.source, "sessions")

    async def test_dry_run_estimates_without_calling_the_model(self):
        directory = self.directory()

        async def forbidden(_transcript):
            raise AssertionError("dry run must not call the model")

        built = await sessions.build_session_plan(
            sessions_dir=directory,
            dry_run=True,
            summarizer=forbidden,
        )
        report = built.report
        self.assertTrue(report["dry_run"])
        self.assertEqual(built.plan.episodes, [])
        self.assertEqual(report["parsed"], 1)
        self.assertEqual(report["summarized"], 0)
        item = report["items"][0]
        self.assertGreater(item["estimated_prompt_tokens"], 0)
        self.assertGreater(item["estimated_cost_usd"], 0)
        self.assertEqual(item["episodes"], 0)
        self.assertAlmostEqual(
            report["estimated_cost_usd"], item["estimated_cost_usd"], places=9
        )
        self.assertGreater(report["estimated_prompt_tokens"], 0)
        self.assertIn("dry run", sessions.summary_line(report))

    async def test_a_failed_summary_skips_only_that_session(self):
        directory = self.directory()
        write_session(directory, "s-2", plain_session("s-2"), mtime=os.path.getmtime(Path(directory, "s-1.jsonl")) + 10)
        seen = []

        async def flaky(transcript):
            seen.append(transcript)
            if "Add a cowsay" in transcript and len(seen) == 1:
                raise summary.SummaryError("gateway exploded")
            return result()

        built = await sessions.build_session_plan(
            sessions_dir=directory,
            summarizer=flaky,
            concurrency=1,
        )
        self.assertEqual(built.report["failed"], 1)
        self.assertEqual(built.report["summarized"], 1)
        self.assertEqual(len(built.plan.skipped), 1)
        self.assertIn("gateway exploded", built.plan.skipped[0].reason)

    async def test_a_work_session_is_refused_before_the_model_runs(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name, "checkout")
        root.mkdir()
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        subprocess.run(
            ["git", "-C", str(root), "remote", "add", "origin", "git@github.com:blitzy-ai/service.git"],
            check=True,
        )
        write_session(self.tmp.name, "work-1", plain_session("work-1", cwd=str(root)))

        async def forbidden(_transcript):
            raise AssertionError("a refused session must not be summarized")

        built = await sessions.build_session_plan(sessions_dir=self.tmp.name, summarizer=forbidden)
        self.assertEqual(built.report["summarized"], 0)
        self.assertEqual(built.report["skipped"], 1)
        self.assertIn("refused", built.report["skips"][0]["reason"])
        self.assertEqual(built.plan.episodes, [])

    async def test_unreadable_sessions_are_skipped_not_fatal(self):
        directory = self.directory()
        Path(directory, "broken.jsonl").write_text("", encoding="utf-8")
        async def ok(_transcript):
            return result()

        built = await sessions.build_session_plan(sessions_dir=directory, summarizer=ok)
        self.assertEqual(built.report["sampled"], 2)
        self.assertEqual(built.report["parsed"], 1)
        self.assertEqual(built.report["skipped"], 1)

    async def test_observer_counts_registry_duplicates_and_submissions(self):
        directory = self.directory()
        async def ok(_transcript):
            return result()

        built = await sessions.build_session_plan(sessions_dir=directory, summarizer=ok)
        observe = sessions.session_observer(built.report)
        episodes = built.plan.episodes
        observe(episodes[0], "active")
        observe(episodes[1], "submitted")
        item = built.report["items"][0]
        self.assertEqual(item["duplicates"], 1)
        self.assertEqual(item["submitted"], 1)
        self.assertEqual(built.report["duplicates"], 1)
        self.assertEqual(built.report["submitted"], 1)
        self.assertIn("1 duplicates, 1 submitted", sessions.summary_line(built.report))

    async def test_the_runner_merges_the_sessions_section_and_observes_episodes(self):
        directory = self.directory()
        async def ok(_transcript):
            return result()

        built = await sessions.build_session_plan(sessions_dir=directory, summarizer=ok)
        observe = sessions.session_observer(built.report)
        statuses = {}

        async def lookup(group, hashes):
            return {digest: {"status": "active", "uuid": "u"} for digest in hashes}

        async def submit(payload):
            return {"status": "queued"}

        with tempfile.TemporaryDirectory() as report_dir:
            runner = IngestRunner(
                RunnerConfig(report_path=str(Path(report_dir, "report.json"))),
                lookup_fn=lookup,
                submit_fn=submit,
            )
            report = await runner.run([built.plan], observer=observe, extras={"sessions": built.report})
            on_disk = json.loads(Path(report_dir, "report.json").read_text())

        self.assertEqual(report["totals"]["active"], 2)
        self.assertEqual(report["sessions"]["items"][0]["duplicates"], 2)
        self.assertEqual(on_disk["sessions"]["items"][0]["duplicates"], 2)

    async def test_a_stable_second_run_submits_nothing(self):
        """Re-running a sample must not duplicate episodes the registry holds."""
        directory = self.directory()

        async def stable(_transcript):
            return result()

        stored: set[str] = set()

        async def lookup(group, hashes):
            return {
                digest: ({"status": "active", "uuid": "u"} if digest in stored else {"status": "missing"})
                for digest in hashes
            }

        async def submit(payload):
            stored.add(content_hash(normalize_content(payload["content"])))
            return {"status": "queued"}

        async def first_run():
            built = await sessions.build_session_plan(sessions_dir=directory, summarizer=stable)
            with tempfile.TemporaryDirectory() as report_dir:
                runner = IngestRunner(
                    RunnerConfig(report_path=str(Path(report_dir, "report.json"))),
                    lookup_fn=lookup,
                    submit_fn=submit,
                )
                return await runner.run([built.plan])

        first = await first_run()
        second = await first_run()
        self.assertEqual(first["totals"]["submitted"], 2)
        self.assertEqual(second["totals"]["submitted"], 0)
        self.assertEqual(second["totals"]["active"], 2)
        self.assertEqual(second["failures"], [])


class ReportTests(unittest.TestCase):
    def test_report_shape_is_stable(self):
        report = {
            "dry_run": False,
            "model": "deepseek-v4.1-flash",
            "sampled": 1,
            "parsed": 1,
            "skipped": 0,
            "summarized": 1,
            "failed": 0,
            "episodes": 3,
            "prompt_tokens": 10,
            "completion_tokens": 5,
            "cost_usd": 0.0,
            "estimated_prompt_tokens": 0,
            "estimated_cost_usd": 0.0,
            "wall_seconds": 1.0,
            "items": [],
            "skips": [],
        }
        line = sessions.summary_line(report)
        self.assertIn("sessions:", line)
        self.assertIn("1 sampled", line)
        self.assertIn("3 episodes", line)


if __name__ == "__main__":
    unittest.main()
