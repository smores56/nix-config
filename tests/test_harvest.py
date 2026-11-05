import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from datetime import date, datetime
from pathlib import Path

ROOT = Path(__file__).parents[1]


def load(rel, name):
    spec = importlib.util.spec_from_file_location(name, ROOT / rel)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def load_module():
    return load("modules/features/ai/harvest/harvest.py", "harvest")


ENV = {
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_AUTHOR_NAME": "t",
    "GIT_AUTHOR_EMAIL": "t@t",
    "GIT_COMMITTER_NAME": "t",
    "GIT_COMMITTER_EMAIL": "t@t",
}
SAVED_ENV = {}


def setUpModule():
    # The harvester works in system local time, as under launchd; pin a zone with DST.
    SAVED_ENV.update(os.environ)
    os.environ.update({**ENV, "TZ": "America/New_York"})
    time.tzset()


def tearDownModule():
    os.environ.clear()
    os.environ.update(SAVED_ENV)
    time.tzset()


def at(text):
    return datetime.fromisoformat(text).astimezone()


def git(repo, *args, env=None):
    return subprocess.run(
        ["git", "-C", str(repo), *args], env={**os.environ, **(env or {})}, check=True, capture_output=True, text=True
    ).stdout


def make_repo(path, when, remote=None):
    path.mkdir(parents=True)
    git(path, "init", "-q")
    if remote:
        git(path, "remote", "add", "origin", remote)
    env = {"GIT_COMMITTER_DATE": when, "GIT_AUTHOR_DATE": when}
    (path / "f").write_text("x")
    git(path, "add", "f", env=env)
    git(path, "commit", "-qm", "first change", env=env)
    return path


def result(structured=None, **extra):
    return json.dumps({"subtype": "success", "is_error": False, "total_cost_usd": 0.01, "structured_output": structured, **extra})


def connector_output(rows=(), calendar="complete", meetings="complete"):
    return result(
        {
            "rows": list(rows),
            "sources": [
                {"source": "calendar", "status": calendar, "detail": ""},
                {"source": "meetings", "status": meetings, "detail": ""},
            ],
        }
    )


class PlanTests(unittest.TestCase):
    def setUp(self):
        self.h = load_module()

    def test_work_day_rolls_over_at_four(self):
        self.assertEqual(self.h.work_day(at("2026-10-14T03:59:00")), date(2026, 10, 13))
        self.assertEqual(self.h.work_day(at("2026-10-14T04:00:00")), date(2026, 10, 14))

    def test_first_run_looks_back_a_week(self):
        start, end = self.h.plan("calendar", {}, date(2026, 10, 14))
        self.assertEqual((start, end), (date(2026, 10, 7), date(2026, 10, 14)))

    def test_git_stops_at_yesterday_so_its_day_episodes_are_final(self):
        start, end = self.h.plan("git", {}, date(2026, 10, 14))
        self.assertEqual(end, date(2026, 10, 13))

    def test_a_run_repulls_the_cursor_day_and_caps_the_backlog(self):
        self.assertEqual(self.h.plan("jira", {"jira": "2026-10-12"}, date(2026, 10, 14))[0], date(2026, 10, 12))
        self.assertEqual(self.h.plan("jira", {"jira": "2026-01-01"}, date(2026, 10, 14))[0], date(2026, 9, 30))

    def test_a_garbled_cursor_is_ignored(self):
        self.assertEqual(self.h.plan("jira", {"jira": "nope"}, date(2026, 10, 14))[0], date(2026, 10, 7))

    def test_no_source_can_be_chat_or_mail(self):
        for name in self.h.SOURCES:
            self.assertNotRegex(name, "(?i)slack|mail|chat|drive")

    def test_group_slug_matches_the_memory_service(self):
        groups = load("modules/features/ai/memory/src/memory_mcp/groups.py", "groups")
        for text in ("Owner/Repo", "a b c", "--x--", "A" * 90):
            self.assertEqual(self.h.slug(text), groups.sanitize_slug(text))


class EpisodeTests(unittest.TestCase):
    def setUp(self):
        self.h = load_module()
        self.tmp = tempfile.TemporaryDirectory()
        self.base = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_git_activity_is_one_episode_per_repo_and_day_named_by_the_remote(self):
        root = self.base / "code"
        repo = make_repo(root / "checkout", "2026-10-14T09:00:00-04:00", "https://tok:en@github.com/acme/widgets.git")
        env = {"GIT_COMMITTER_DATE": "2026-10-14T10:00:00-04:00", "GIT_AUTHOR_DATE": "2026-10-14T10:00:00-04:00"}
        git(repo, "commit", "-q", "--allow-empty", "-m", "second change", env=env)
        eps = self.h.git_episodes((root,), date(2026, 10, 14), date(2026, 10, 14), "sam")
        self.assertEqual(len(eps), 1)
        self.assertIn("2026-10-14", eps[0])
        self.assertIn("acme/widgets", eps[0])
        self.assertIn("commit: first change", eps[0])
        self.assertIn("commit: second change", eps[0])
        self.assertNotIn("tok", eps[0])

    def test_git_without_a_remote_falls_back_to_the_directory_name(self):
        root = self.base / "code"
        make_repo(root / "scratch", "2026-10-14T09:00:00-04:00")
        (ep,) = self.h.git_episodes((root,), date(2026, 10, 14), date(2026, 10, 14), "sam")
        self.assertIn("scratch", ep)

    def test_git_ignores_days_outside_the_window_and_navigation(self):
        root = self.base / "code"
        repo = make_repo(root / "r", "2026-10-14T09:00:00-04:00")
        git(repo, "checkout", "-q", "-b", "side")
        self.assertEqual(self.h.git_episodes((root,), date(2026, 10, 15), date(2026, 10, 16), "sam"), [])
        (ep,) = self.h.git_episodes((root,), date(2026, 10, 14), date(2026, 10, 14), "sam")
        self.assertNotIn("checkout", ep)

    def test_git_worktrees_outside_the_roots_are_not_scanned(self):
        root = self.base / "code"
        repo = make_repo(root / "r", "2026-10-14T09:00:00-04:00")
        outside = self.base / "elsewhere"
        git(repo, "worktree", "add", "-q", str(outside), "-b", "side")
        env = {"GIT_COMMITTER_DATE": "2026-10-14T10:00:00-04:00", "GIT_AUTHOR_DATE": "2026-10-14T10:00:00-04:00"}
        git(outside, "commit", "-q", "--allow-empty", "-m", "outside work", env=env)
        (ep,) = self.h.git_episodes((root,), date(2026, 10, 14), date(2026, 10, 14), "sam")
        self.assertNotIn("outside work", ep)

    def test_git_subjects_are_redacted(self):
        root = self.base / "code"
        repo = make_repo(root / "r", "2026-10-14T09:00:00-04:00")
        env = {"GIT_COMMITTER_DATE": "2026-10-14T10:00:00-04:00", "GIT_AUTHOR_DATE": "2026-10-14T10:00:00-04:00"}
        git(repo, "commit", "-q", "--allow-empty", "-m", "token ghp_" + "x" * 30, env=env)
        (ep,) = self.h.git_episodes((root,), date(2026, 10, 14), date(2026, 10, 14), "sam")
        self.assertNotIn("ghp_", ep)

    def test_git_lines_per_episode_are_capped(self):
        root = self.base / "code"
        repo = make_repo(root / "r", "2026-10-14T09:00:00-04:00")
        self.h.GIT_LINES_PER_EPISODE = 2
        for i in range(3):
            when = f"2026-10-14T10:0{i}:00-04:00"
            git(repo, "commit", "-q", "--allow-empty", "-m", f"c{i}", env={"GIT_COMMITTER_DATE": when, "GIT_AUTHOR_DATE": when})
        (ep,) = self.h.git_episodes((root,), date(2026, 10, 14), date(2026, 10, 14), "sam")
        self.assertIn("c2", ep)
        self.assertNotIn("first change", ep)
        self.assertIn("2 earlier", ep)

    def test_pull_requests_merge_roles_and_leave_out_volatile_times(self):
        pr = {"url": "https://github.com/acme/widgets/pull/7", "title": "Fix it", "state": "merged", "isDraft": False,
              "updatedAt": "2026-10-14T10:00:00Z", "closedAt": "2026-10-14T10:00:00Z"}
        eps = self.h.pr_episodes({"author": [pr], "reviewer": [pr], "commenter": []}, "sam")
        (ep,) = eps
        self.assertIn("authored and reviewed", ep)
        self.assertIn("acme/widgets", ep)
        self.assertIn("merged", ep)
        self.assertNotIn("10:00", ep)
        later = {**pr, "updatedAt": "2026-10-15T09:00:00Z"}
        self.assertEqual(self.h.pr_episodes({"author": [later], "reviewer": [pr], "commenter": []}, "sam"), eps)

    def test_a_state_change_is_a_new_episode(self):
        pr = {"url": "https://github.com/a/b/pull/1", "title": "T", "state": "open", "isDraft": True}
        a = self.h.pr_episodes({"author": [pr]}, "sam")
        b = self.h.pr_episodes({"author": [{**pr, "state": "merged"}]}, "sam")
        self.assertNotEqual(a, b)

    def test_jira_reads_both_flat_and_nested_items(self):
        out = json.dumps([
            {"key": "FOO-1", "fields": {"summary": "Nested", "status": {"name": "In Progress"}}},
            {"key": "FOO-2", "summary": "Flat", "status": "Done"},
            {"summary": "no key"},
        ])
        eps = self.h.jira_episodes(out, "sam")
        self.assertEqual(len(eps), 2)
        self.assertIn("FOO-1", eps[0])
        self.assertIn("In Progress", eps[0])
        self.assertIn("Done", eps[1])

    def test_jira_rejects_output_that_is_not_a_list(self):
        with self.assertRaises(ValueError):
            self.h.jira_episodes('{"error": "x"}', "sam")

    def test_connector_rows_become_episodes_and_bad_rows_are_dropped(self):
        rows = [
            {"source": "calendar", "day": "2026-10-14", "title": "Planning sync"},
            {"source": "meetings", "day": "2026-10-14", "title": "Design review", "url": "https://notes.granola.ai/d/abc"},
            {"source": "meetings", "day": "2026-10-14", "title": "Bad link", "url": "javascript:alert(1)"},
            {"source": "slack", "day": "2026-10-14", "title": "Chat thread"},
            {"source": "calendar", "day": "2026-09-01", "title": "Out of window"},
            {"source": "calendar", "day": "yesterday", "title": "No date"},
            {"source": "calendar", "day": "2026-10-14", "title": "  "},
        ]
        got = self.h.connector_episodes(rows, date(2026, 10, 10), date(2026, 10, 14), "sam")
        self.assertEqual(len(got["calendar"]), 1)
        self.assertIn("Planning sync", got["calendar"][0])
        self.assertEqual(len(got["meetings"]), 2)
        self.assertIn("https://notes.granola.ai/d/abc", "".join(got["meetings"]))
        self.assertNotIn("javascript", "".join(got["meetings"]))
        self.assertNotIn("slack", got)


class ConnectorSettingsTests(unittest.TestCase):
    def setUp(self):
        self.h = load_module()
        self.perms = self.h.connector_settings()["permissions"]

    def test_only_calendar_and_meeting_title_tools_are_allowed(self):
        self.assertEqual(
            set(self.perms["allow"]),
            {
                "mcp__claude_ai_Google_Calendar__list_calendars",
                "mcp__claude_ai_Google_Calendar__list_events",
                "mcp__claude_ai_Granola__search_meetings",
            },
        )

    def test_chat_mail_and_other_servers_are_denied_and_never_allowed(self):
        for server in ("Slack", "Gmail", "Google_Drive", "Notion", "Atlassian_Rovo"):
            self.assertIn(f"mcp__claude_ai_{server}", self.perms["deny"])
        for tool in self.perms["allow"]:
            self.assertNotRegex(tool, "(?i)slack|gmail|mail|chat")

    def test_shell_web_and_files_are_denied(self):
        for tool in ("Bash", "WebFetch", "WebSearch", "Agent", "Read", "Write", "Edit"):
            self.assertIn(tool, self.perms["deny"])

    def test_transcript_tools_are_denied(self):
        self.assertIn("mcp__claude_ai_Granola__get_meeting_transcript", self.perms["deny"])
        self.assertIn("mcp__claude_ai_Granola__get_meetings", self.perms["deny"])


class ParseTests(unittest.TestCase):
    def setUp(self):
        self.h = load_module()

    def test_parses_rows_and_statuses(self):
        rows = [{"source": "calendar", "day": "2026-10-14", "title": "x"}]
        got_rows, statuses, error, cost = self.h.parse_connectors(connector_output(rows, meetings="failed"))
        self.assertEqual((got_rows, statuses, error, cost), (rows, {"calendar": "complete", "meetings": "failed"}, None, 0.01))

    def test_errors_are_reported(self):
        for out in ("not json", json.dumps({"subtype": "error_max_turns", "is_error": True}), result(None)):
            _, _, error, _ = self.h.parse_connectors(out)
            self.assertTrue(error)


class FakeTools:
    def __init__(self, h, prs=(), jira="[]", claude=None, memory_fails=False):
        self.h, self.prs, self.jira = h, list(prs), jira
        self.claude_out = claude or connector_output()
        self.memory_fails = memory_fails
        self.written, self.gh_calls, self.acli_calls, self.claude_calls = [], [], [], []

    def tools(self):
        return self.h.Tools(gh=self.gh, acli=self.acli, claude=self.claude, memory=self.memory)

    def gh(self, args):
        self.gh_calls.append(args)
        return json.dumps(self.prs)

    def acli(self, args):
        self.acli_calls.append(args)
        return self.jira

    def claude(self, args, prompt, cwd, timeout):
        self.claude_calls.append((args, prompt))
        return self.claude_out

    def memory(self, text):
        if self.memory_fails:
            raise self.h.MemoryWriteError("server unreachable")
        self.written.append(text)


class HarvestTests(unittest.TestCase):
    def setUp(self):
        self.h = load_module()
        self.tmp = tempfile.TemporaryDirectory()
        self.base = Path(self.tmp.name)
        self.root = self.base / "code"
        make_repo(self.root / "r", "2026-10-13T09:00:00-04:00", "git@github.com:acme/widgets.git")
        self.config = self.h.Config(state_dir=self.base / "state", repo_roots=(self.root,), user="sam")
        self.pr = {"url": "https://github.com/acme/widgets/pull/7", "title": "Fix", "state": "open", "isDraft": False}
        self.jira = json.dumps([{"key": "FOO-1", "fields": {"summary": "S", "status": {"name": "Done"}}}])
        self.rows = [{"source": "calendar", "day": "2026-10-14", "title": "Sync"}]
        self.now = at("2026-10-14T17:30:00")

    def tearDown(self):
        self.tmp.cleanup()

    def run_harvest(self, fake, now=None, **kw):
        return self.h.harvest(self.config, now or self.now, fake.tools(), **kw)

    def fake(self, **kw):
        return FakeTools(self.h, prs=[self.pr], jira=self.jira, claude=connector_output(self.rows), **kw)

    def cursors(self):
        return json.loads((self.config.state_dir / "cursors.json").read_text())

    def test_every_source_lands_as_episodes_and_the_cursors_advance(self):
        fake = self.fake()
        code, message = self.run_harvest(fake)
        self.assertEqual(code, 0, message)
        text = "\n".join(fake.written)
        for needle in ("acme/widgets", "pull request", "FOO-1", "Sync"):
            self.assertIn(needle, text)
        self.assertEqual(self.cursors(), {"git": "2026-10-13", "github": "2026-10-14", "jira": "2026-10-14",
                                          "calendar": "2026-10-14", "meetings": "2026-10-14"})

    def test_a_rerun_writes_the_same_texts_so_the_store_deduplicates(self):
        first, second = self.fake(), self.fake()
        self.run_harvest(first)
        (self.config.state_dir / "cursors.json").unlink()
        self.run_harvest(second, now=at("2026-10-14T18:00:00"))
        self.assertEqual(sorted(first.written), sorted(second.written))

    def test_a_source_that_fails_holds_its_cursor_and_the_rest_advance(self):
        fake = self.fake()
        fake.acli = lambda args: (_ for _ in ()).throw(subprocess.CalledProcessError(1, "acli", stderr="not logged in"))
        code, message = self.run_harvest(fake)
        self.assertEqual(code, 1)
        self.assertIn("jira", message)
        self.assertIn("not logged in", message)
        self.assertNotIn("jira", self.cursors())
        self.assertIn("github", self.cursors())

    def test_a_failed_connector_status_holds_only_that_source(self):
        fake = self.fake()
        fake.claude_out = connector_output(self.rows, meetings="failed")
        self.run_harvest(fake)
        self.assertIn("calendar", self.cursors())
        self.assertNotIn("meetings", self.cursors())

    def test_memory_down_stops_the_run_and_advances_nothing(self):
        fake = self.fake(memory_fails=True)
        code, message = self.run_harvest(fake)
        self.assertEqual(code, 1)
        self.assertIn("memory", message)
        self.assertFalse((self.config.state_dir / "cursors.json").exists())

    def test_dry_run_writes_nothing_and_keeps_cursors(self):
        fake = self.fake()
        printed = []
        code, _ = self.run_harvest(fake, dry_run=printed.append)
        self.assertEqual(code, 0)
        self.assertEqual(fake.written, [])
        self.assertTrue(printed)
        self.assertFalse((self.config.state_dir / "cursors.json").exists())

    def test_queries_start_at_each_sources_window(self):
        fake = self.fake()
        self.run_harvest(fake)
        self.assertTrue(all("--updated=>=2026-10-07" in args for args in fake.gh_calls))
        jql = fake.acli_calls[0][fake.acli_calls[0].index("--jql") + 1]
        self.assertIn("2026-10-07", jql)
        self.assertIn("currentUser()", jql)
        _, prompt = fake.claude_calls[0]
        self.assertIn("2026-10-07", prompt)
        self.assertIn("2026-10-14", prompt)

    def test_connector_output_is_data_not_instructions_in_the_prompt(self):
        fake = self.fake()
        self.run_harvest(fake)
        args, _ = fake.claude_calls[0]
        self.assertIn("--setting-sources", args)
        self.assertEqual(args[args.index("--permission-mode") + 1], "dontAsk")

    def test_unattended_run_skips_when_offline(self):
        fake = self.fake()
        notes = []
        code = self.h.unattended(self.config, self.now, fake.tools(), notify=notes.append, online=lambda: False)
        self.assertEqual(code, 1)
        self.assertEqual(fake.written, [])
        self.assertIn("offline", notes[0])


class MemoryCliTests(unittest.TestCase):
    def test_writes_to_the_global_group_through_stdin(self):
        h = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            bin_dir = Path(tmp)
            fake = bin_dir / "memory"
            log = bin_dir / "log"
            fake.write_text(f'#!/bin/sh\nprintf "%s\\n" "$*" >> {log}\ncat >> {log}\n')
            fake.chmod(0o755)
            h.memory_writer(str(fake))("hello episode")
            self.assertEqual(log.read_text(), "--group global write -\nhello episode")

    def test_a_failing_cli_raises(self):
        h = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            fake = Path(tmp) / "memory"
            fake.write_text("#!/bin/sh\necho unreachable >&2\nexit 1\n")
            fake.chmod(0o755)
            with self.assertRaisesRegex(h.MemoryWriteError, "unreachable"):
                h.memory_writer(str(fake))("x")


if __name__ == "__main__":
    unittest.main()
