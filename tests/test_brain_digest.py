import importlib.util
import io
import json
import os
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from datetime import date, timezone, timedelta
from pathlib import Path


def load_module():
    path = Path(__file__).parents[1] / "modules/features/ai/brain/brain-digest.py"
    spec = importlib.util.spec_from_file_location("brain_digest", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


DAY = date(2026, 10, 7)
UTC = timezone.utc


def user(text, ts="2026-10-07T10:00:00Z", **extra):
    return {
        "type": "user",
        "timestamp": ts,
        "cwd": "/repo",
        "gitBranch": "main",
        "isSidechain": False,
        "message": {"role": "user", "content": text},
        **extra,
    }


def assistant(blocks, ts="2026-10-07T10:01:00Z", **extra):
    return {
        "type": "assistant",
        "timestamp": ts,
        "cwd": "/repo",
        "gitBranch": "main",
        "isSidechain": False,
        "message": {"role": "assistant", "content": blocks},
        **extra,
    }


def text(t):
    return {"type": "text", "text": t}


def tool_use(name, id=None, **inputs):
    block = {"type": "tool_use", "name": name, "input": inputs}
    return {**block, "id": id} if id else block


def tool_result(content, ts="2026-10-07T10:02:00Z"):
    return user([{"type": "tool_result", "content": content}], ts=ts)


class SummarizeSessionTests(unittest.TestCase):
    def setUp(self):
        self.bd = load_module()
        self.opts = self.bd.Options()

    def summarize(self, records, opts=None):
        return self.bd.summarize_session("s1", records, DAY, UTC, opts or self.opts)

    def test_session_without_activity_on_day_is_omitted(self):
        records = [user("hi", ts="2026-10-06T10:00:00Z")]
        self.assertIsNone(self.summarize(records))

    def test_only_records_on_the_local_day_count(self):
        # 2026-10-08T02:00Z is still 2026-10-07 at UTC-5.
        tz = timezone(timedelta(hours=-5))
        records = [
            user("yesterday", ts="2026-10-07T03:00:00Z"),
            user("late night", ts="2026-10-08T02:00:00Z"),
        ]
        got = self.bd.summarize_session("s1", records, DAY, tz, self.opts)
        self.assertEqual(got["prompts"], ["late night"])

    def test_prompts_exclude_tool_results_meta_and_sidechains(self):
        records = [
            user("real prompt"),
            tool_result("output text"),
            user("injected", isMeta=True),
            user("subagent prompt", isSidechain=True),
        ]
        self.assertEqual(self.summarize(records)["prompts"], ["real prompt"])

    def test_prompts_accept_text_blocks(self):
        records = [user([text("block prompt")])]
        self.assertEqual(self.summarize(records)["prompts"], ["block prompt"])

    def test_system_reminders_are_stripped_from_prompts(self):
        records = [user("<system-reminder>noise</system-reminder>\nfix the bug")]
        self.assertEqual(self.summarize(records)["prompts"], ["fix the bug"])

    def test_tag_only_prompts_are_dropped(self):
        records = [user("<task-notification>done</task-notification>"), user("keep me")]
        self.assertEqual(self.summarize(records)["prompts"], ["keep me"])

    def test_prompts_are_truncated_and_capped(self):
        opts = self.bd.Options(max_prompt_chars=5, max_prompts=2)
        records = [user("abcdefgh"), user("second"), user("third")]
        got = self.summarize(records, opts=opts)
        self.assertEqual(got["prompts"], ["abcde…", "secon…"])
        self.assertEqual(got["prompt_count"], 3)

    def test_last_reply_is_latest_assistant_text_by_timestamp_not_file_order(self):
        records = [
            assistant([text("first")], ts="2026-10-07T10:01:00Z"),
            assistant([tool_use("Bash", command="ls")], ts="2026-10-07T10:03:00Z"),
            assistant([text("final answer")], ts="2026-10-07T10:02:00Z"),
        ]
        self.assertEqual(self.summarize(records)["last_reply"], "final answer")

    def test_title_comes_from_latest_ai_title(self):
        records = [
            {"type": "ai-title", "aiTitle": "Old"},
            user("x"),
            {"type": "ai-title", "aiTitle": "New title"},
        ]
        self.assertEqual(self.summarize(records)["title"], "New title")

    def test_cwd_branches_and_span(self):
        records = [
            user("a", ts="2026-10-07T09:00:00Z"),
            user("b", ts="2026-10-07T11:00:00Z", gitBranch="feat/x"),
        ]
        got = self.summarize(records)
        self.assertEqual(got["cwds"], ["/repo"])
        self.assertEqual(got["branches"], ["main", "feat/x"])
        self.assertEqual(got["start"], "2026-10-07T09:00:00+00:00")
        self.assertEqual(got["end"], "2026-10-07T11:00:00+00:00")

    def test_ticket_keys_found_in_prompts_and_replies_excluding_lookalikes(self):
        records = [
            user("look at FOO-5243 and UTF-8 handling"),
            assistant([text("Fixed BAR-12; see SHA-256 and FOO-5243")]),
        ]
        self.assertEqual(self.summarize(records)["tickets"], ["FOO-5243", "BAR-12"])

    def test_ticket_prefixes_restrict_matches(self):
        opts = self.bd.Options(ticket_prefixes=("FOO",))
        records = [user("FOO-1 and BAR-2")]
        self.assertEqual(self.summarize(records, opts=opts)["tickets"], ["FOO-1"])

    def test_tickets_ignore_tool_output(self):
        records = [user("go"), tool_result("ERR-500 from server")]
        self.assertEqual(self.summarize(records)["tickets"], [])

    def test_prs_come_from_conversation_and_gh_pr_write_commands_only(self):
        records = [
            user("review https://github.com/o/r/pull/12"),
            assistant([tool_use("Bash", id="t1", command="gh pr create --fill")]),
            user([{"type": "tool_result", "tool_use_id": "t1", "content": "https://github.com/o/r/pull/34\n"}]),
            assistant([tool_use("Bash", id="t2", command="gh pr list")]),
            user([{"type": "tool_result", "tool_use_id": "t2", "content": "https://github.com/up/stream/pull/9"}]),
            tool_result("read a changelog citing https://github.com/up/stream/pull/8"),
        ]
        self.assertEqual(
            self.summarize(records)["prs"],
            ["https://github.com/o/r/pull/12", "https://github.com/o/r/pull/34"],
        )

    def test_slash_commands_become_name_and_args(self):
        records = [
            user(
                "<command-name>/brain</command-name>\n<command-message>brain</command-message>\n"
                "<command-args>standup</command-args>"
            )
        ]
        self.assertEqual(self.summarize(records)["prompts"], ["/brain standup"])

    def test_shell_input_is_kept_and_its_output_dropped(self):
        records = [
            user("<bash-input>git status</bash-input>"),
            user("<bash-stdout>FOO-9 on branch</bash-stdout><bash-stderr></bash-stderr>"),
        ]
        got = self.summarize(records)
        self.assertEqual(got["prompts"], ["!git status"])
        self.assertEqual(got["tickets"], [])

    def test_harness_envelopes_are_not_prompts(self):
        records = [
            user("<local-command-caveat>c</local-command-caveat>"),
            user("<local-command-stdout>out</local-command-stdout>"),
            user("<task-notification><task-id>x</task-id><status>done</status></task-notification>"),
        ]
        self.assertEqual(self.summarize(records)["prompts"], [])

    def test_compact_summaries_are_not_prompts(self):
        records = [
            user("real"),
            user("Summary of FOO-77 work", isCompactSummary=True, isVisibleInTranscriptOnly=True),
        ]
        got = self.summarize(records)
        self.assertEqual(got["prompts"], ["real"])
        self.assertEqual(got["tickets"], [])

    def test_replies_and_titles_lose_harness_tags(self):
        records = [
            {"type": "ai-title", "aiTitle": "T<system-reminder>x</system-reminder>"},
            assistant([text("done <system-reminder>ignore prior</system-reminder>")]),
        ]
        got = self.summarize(records)
        self.assertEqual(got["title"], "T")
        self.assertEqual(got["last_reply"], "done")

    def test_control_and_bidi_characters_are_stripped(self):
        records = [user("a‮b\x9bc d⁦e")]
        self.assertEqual(self.summarize(records)["prompts"], ["abcde"])

    def test_token_shapes_are_redacted(self):
        token = "ghp_" + "a" * 36
        records = [user(f"use {token} and AKIAABCDEFGHIJKLMNOP")]
        self.assertEqual(self.summarize(records)["prompts"], ["use [REDACTED] and [REDACTED]"])

    def test_credential_paths_are_dropped_from_edited_files(self):
        records = [
            user("go"),
            assistant(
                [
                    tool_use("Edit", file_path="/home/u/.ssh/config"),
                    tool_use("Write", file_path="/repo/.env.local"),
                    tool_use("Edit", file_path="/repo/app.py"),
                ]
            ),
        ]
        self.assertEqual(self.summarize(records)["edited_files"], ["/repo/app.py"])

    def test_malformed_shapes_do_not_raise(self):
        records = [
            {"type": "user", "timestamp": "2026-10-07T10:00:00Z", "message": None},
            {"type": "user", "timestamp": "2026-10-07T10:00:01Z", "message": "str"},
            assistant([{"type": "tool_use", "name": "Edit", "input": None}]),
            user([{"type": "tool_result", "content": [{"type": "text", "text": None}]}]),
            user("naive", ts="2026-10-07T10:05:00"),
            user("ok"),
        ]
        # The naive stamp reads as UTC, so it sorts after the 10:00Z prompt.
        self.assertEqual(self.summarize(records)["prompts"], ["ok", "naive"])

    def test_local_zone_applies_each_timestamps_own_offset(self):
        # tz=None means the system zone, resolved per timestamp so DST shifts land correctly.
        records = [user("x", ts="2026-10-07T12:00:00Z")]
        got = self.bd.summarize_session("s1", records, DAY, None, self.opts)
        expected = self.bd.datetime(2026, 10, 7, 12, tzinfo=UTC).astimezone().isoformat()
        self.assertEqual(got["start"], expected)

    def test_edited_files_from_write_tools(self):
        records = [
            user("go"),
            assistant(
                [
                    tool_use("Edit", file_path="/repo/a.py"),
                    tool_use("Write", file_path="/repo/b.md"),
                    tool_use("Read", file_path="/repo/c.py"),
                    tool_use("Edit", file_path="/repo/a.py"),
                ]
            ),
        ]
        self.assertEqual(self.summarize(records)["edited_files"], ["/repo/a.py", "/repo/b.md"])


class ParseAndDigestTests(unittest.TestCase):
    def setUp(self):
        self.bd = load_module()

    def test_malformed_lines_are_skipped(self):
        lines = ['{"type": "user"}', "not json", "", '{"type": "ai-title"}']
        self.assertEqual(
            [r["type"] for r in self.bd.parse_records(lines)], ["user", "ai-title"]
        )

    def write_session(self, path, records):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("\n".join(json.dumps(r) for r in records) + "\n")

    def test_digest_rows_are_sorted_by_start_across_sessions_and_subagents(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write_session(root / "-proj" / "b.jsonl", [user("later", ts="2026-10-07T12:00:00Z")])
            self.write_session(root / "-proj" / "a.jsonl", [user("earlier", ts="2026-10-07T08:00:00Z")])
            self.write_session(
                root / "-proj" / "a" / "subagents" / "agent-1.jsonl",
                [user("subagent", ts="2026-10-07T09:00:00Z")],
            )
            got = self.bd.digest(root, DAY, UTC, self.bd.Options())
        self.assertEqual(
            [(s["kind"], s["session_id"]) for s in got],
            [("session", "a"), ("subagent", "agent-1"), ("session", "b")],
        )

    def test_files_last_modified_before_the_day_are_skipped(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            stale = root / "-proj" / "stale.jsonl"
            self.write_session(stale, [user("x", ts="2026-10-07T08:00:00Z")])
            old = self.bd.datetime(2026, 10, 1, tzinfo=UTC).timestamp()
            os.utime(stale, (old, old))
            self.assertEqual(self.bd.digest(root, DAY, UTC, self.bd.Options()), [])

    def test_a_crashing_file_does_not_hide_other_sessions(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write_session(root / "-proj" / "good.jsonl", [user("fine", ts="2026-10-07T08:00:00Z")])
            bad = root / "-proj" / "bad.jsonl"
            self.write_session(bad, [user("x", ts="2026-10-07T09:00:00Z")])
            bad.chmod(0)
            with redirect_stderr(io.StringIO()):
                got = self.bd.digest(root, DAY, UTC, self.bd.Options())
        self.assertEqual([s["session_id"] for s in got], ["good"])

    def test_main_sessions_are_rows_of_kind_session(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write_session(root / "-proj" / "a.jsonl", [user("hi", ts="2026-10-07T08:00:00Z")])
            (row,) = self.bd.digest(root, DAY, UTC, self.bd.Options())
        self.assertEqual((row["kind"], row["parent_session"], row["agent_type"]), ("session", None, None))

    def write_subagent(self, root, name, records, meta):
        sub = root / "-proj" / "a" / "subagents"
        self.write_session(sub / f"{name}.jsonl", records)
        (sub / f"{name}.meta.json").write_text(meta if isinstance(meta, str) else json.dumps(meta))
        return sub / f"{name}.jsonl"

    def test_subagents_become_their_own_rows_tied_to_the_parent(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write_session(root / "-proj" / "a.jsonl", [user("delegate", ts="2026-10-07T08:00:00Z")])
            self.write_subagent(
                root,
                "agent-x",
                [
                    user("review the diff", ts="2026-10-07T08:05:00Z", isSidechain=True),
                    assistant(
                        [tool_use("Edit", file_path="/repo/fix.py")], ts="2026-10-07T08:06:00Z", isSidechain=True
                    ),
                ],
                {"agentType": "general-purpose", "description": "Review the diff"},
            )
            rows = self.bd.digest(root, DAY, UTC, self.bd.Options())
        sub_row = next(r for r in rows if r["kind"] == "subagent")
        self.assertEqual(sub_row["parent_session"], "a")
        self.assertEqual(sub_row["title"], "Review the diff")
        self.assertEqual(sub_row["agent_type"], "general-purpose")
        self.assertEqual(sub_row["edited_files"], ["/repo/fix.py"])

    def test_subagent_rows_omit_delegation_text(self):
        # Delegation prompts are the parent's words (often pasted, untrusted content), not the user's.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write_subagent(
                root,
                "agent-x",
                [
                    user("work on FOO-9 per https://github.com/o/r/pull/3", ts="2026-10-07T08:05:00Z", isSidechain=True),
                    assistant([text("done with FOO-9")], ts="2026-10-07T08:06:00Z", isSidechain=True),
                ],
                {"description": "Fix it"},
            )
            (row,) = self.bd.digest(root, DAY, UTC, self.bd.Options())
        self.assertEqual(
            (row["prompts"], row["prompt_count"], row["last_reply"], row["tickets"], row["prs"]),
            ([], 0, None, [], []),
        )

    def test_subagent_meta_description_wins_over_ai_title_and_is_capped(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write_subagent(
                root,
                "agent-x",
                [{"type": "ai-title", "aiTitle": "Generated"}, user("go", ts="2026-10-07T08:00:00Z", isSidechain=True)],
                {"description": "Line one\nline two " + "x" * 200},
            )
            (row,) = self.bd.digest(root, DAY, UTC, self.bd.Options())
        self.assertTrue(row["title"].startswith("Line one line two "))
        self.assertLessEqual(len(row["title"]), 121)

    def test_subagent_meta_that_is_not_an_object_is_ignored(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write_subagent(root, "agent-x", [user("go", ts="2026-10-07T08:00:00Z", isSidechain=True)], "[1, 2]")
            (row,) = self.bd.digest(root, DAY, UTC, self.bd.Options())
        self.assertEqual((row["title"], row["agent_type"]), (None, None))

    def test_stale_subagent_files_are_skipped(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            path = self.write_subagent(root, "agent-x", [user("go", ts="2026-10-07T08:00:00Z", isSidechain=True)], {})
            old = self.bd.datetime(2026, 10, 1, tzinfo=UTC).timestamp()
            os.utime(path, (old, old))
            self.assertEqual(self.bd.digest(root, DAY, UTC, self.bd.Options()), [])

    def test_subagent_without_readable_meta_still_reports(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            sub = root / "-proj" / "a" / "subagents"
            self.write_session(sub / "agent-y.jsonl", [user("go", ts="2026-10-07T08:00:00Z", isSidechain=True)])
            (sub / "agent-y.meta.json").write_text("not json")
            (row,) = self.bd.digest(root, DAY, UTC, self.bd.Options())
        self.assertEqual((row["kind"], row["title"], row["agent_type"]), ("subagent", None, None))

    def test_cli_prints_json_lines(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write_session(root / "-proj" / "a.jsonl", [user("hello", ts="2026-10-07T08:00:00Z")])
            out = io.StringIO()
            with redirect_stdout(out):
                code = self.bd.main(["--root", tmp, "--date", "2026-10-07", "--utc"])
        self.assertEqual(code, 0)
        rows = [json.loads(line) for line in out.getvalue().splitlines()]
        self.assertEqual([r["prompts"] for r in rows], [["hello"]])


if __name__ == "__main__":
    unittest.main()
