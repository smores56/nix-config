import importlib.util
import io
import json
import os
import subprocess
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from datetime import date, datetime, timedelta, timezone
from pathlib import Path


def load_module():
    path = Path(__file__).parents[1] / "modules/features/ai/brain/brain-run.py"
    spec = importlib.util.spec_from_file_location("brain_run", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


UTC = timezone.utc
ENV = {
    **os.environ,
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_AUTHOR_NAME": "t",
    "GIT_AUTHOR_EMAIL": "t@t",
    "GIT_COMMITTER_NAME": "t",
    "GIT_COMMITTER_EMAIL": "t@t",
}


def at(text):
    return datetime.fromisoformat(text).replace(tzinfo=UTC)


def git(repo, *args, env=None):
    return subprocess.run(
        ["git", "-C", str(repo), *args], env=env or ENV, check=True, capture_output=True, text=True
    ).stdout


class PureTests(unittest.TestCase):
    def setUp(self):
        self.br = load_module()

    def test_work_before_four_am_belongs_to_the_previous_day(self):
        self.assertEqual(self.br.work_day(at("2026-10-14T03:59:00")), date(2026, 10, 13))
        self.assertEqual(self.br.work_day(at("2026-10-14T04:00:00")), date(2026, 10, 14))

    def test_days_start_at_the_earliest_source_cursor(self):
        cursors = {s: "2026-10-14T17:30:00+00:00" for s in self.br.SOURCES}
        cursors["mail"] = "2026-10-12T17:30:00+00:00"
        days, truncated = self.br.plan_days(cursors, date(2026, 10, 1), date(2026, 10, 15), UTC)
        self.assertEqual(days, [date(2026, 10, 12), date(2026, 10, 13), date(2026, 10, 14), date(2026, 10, 15)])
        self.assertFalse(truncated)

    def test_a_source_without_a_cursor_starts_at_the_default_day(self):
        cursors = {s: "2026-10-14T17:30:00+00:00" for s in self.br.SOURCES if s != "chat"}
        days, _ = self.br.plan_days(cursors, date(2026, 10, 13), date(2026, 10, 14), UTC)
        self.assertEqual(days[0], date(2026, 10, 13))

    def test_the_cursor_day_is_always_rebuilt(self):
        # A same-day re-run must rebuild today in full, never write a delta-only note.
        cursors = {s: "2026-10-14T17:30:00+00:00" for s in self.br.SOURCES}
        days, _ = self.br.plan_days(cursors, date(2026, 10, 1), date(2026, 10, 14), UTC)
        self.assertEqual(days, [date(2026, 10, 14)])

    def test_a_long_backlog_is_capped(self):
        days, truncated = self.br.plan_days({}, date(2026, 10, 1), date(2026, 10, 20), UTC, cap=5)
        self.assertEqual(days, [date(2026, 10, d) for d in range(1, 6)])
        self.assertTrue(truncated)

    def test_cursors_in_the_future_never_skip_today(self):
        cursors = {s: "2026-10-30T00:00:00+00:00" for s in self.br.SOURCES}
        days, _ = self.br.plan_days(cursors, date(2026, 10, 1), date(2026, 10, 14), UTC)
        self.assertEqual(days, [date(2026, 10, 14)])

    def test_advance_moves_only_completed_sources(self):
        read = {"chat": "a", "mail": "a"}
        got = self.br.advance(read, read, ["chat"], "T")
        self.assertEqual(got, {"chat": "T", "mail": "a"})

    def test_advance_never_overwrites_a_cursor_moved_by_another_run(self):
        got = self.br.advance({"chat": "newer"}, {"chat": "a"}, ["chat"], "T")
        self.assertEqual(got, {"chat": "newer"})

    def test_advance_sets_a_first_cursor(self):
        self.assertEqual(self.br.advance({}, {}, ["git"], "T"), {"git": "T"})

    def test_ticket_prefixes_come_from_their_vault_section_only(self):
        config = "# Vault\n\n## Ticket prefixes\n\nFOO\nBAR2\nnot-a-key\n<KEY> (x)\n\n## Sources\nBAZ\n"
        self.assertEqual(self.br.ticket_prefixes(config), ("FOO", "BAR2"))

    def test_no_ticket_section_means_no_prefixes(self):
        self.assertEqual(self.br.ticket_prefixes("# Vault\n"), ())

    def test_reflog_keeps_work_inside_the_window_and_drops_navigation(self):
        lines = [
            "a" * 40 + "\0HEAD@{2026-10-14T10:00:00+00:00}\0commit: add parser",
            "b" * 40 + "\0HEAD@{2026-10-14T11:00:00+00:00}\0checkout: moving from main to x",
            "c" * 40 + "\0HEAD@{2026-10-14T12:00:00+00:00}\0pull --ff-only: Fast-forward",
            "d" * 40 + "\0HEAD@{2026-10-13T12:00:00+00:00}\0commit: yesterday",
            "e" * 40 + "\0HEAD@{2026-10-15T00:00:00+00:00}\0commit: after window",
        ]
        rows = self.br.reflog_rows(
            Path("/r"), lines, at("2026-10-14T00:00:00"), at("2026-10-15T00:00:00"), UTC
        )
        self.assertEqual([(r["action"], r["subject"]) for r in rows], [
            ("commit", "add parser"),
            ("pull --ff-only", "Fast-forward"),
        ])

    def test_reflog_subjects_are_redacted(self):
        lines = ["a" * 40 + "\0HEAD@{2026-10-14T10:00:00+00:00}\0commit: token ghp_" + "x" * 30]
        (row,) = self.br.reflog_rows(Path("/r"), lines, at("2026-10-14T00:00:00"), at("2026-10-15T00:00:00"), UTC)
        self.assertNotIn("ghp_", row["subject"])

    def test_pr_rows_merge_roles_by_url(self):
        pr = {"url": "https://github.com/o/r/pull/1", "title": "Fix", "state": "open", "updatedAt": "2026-10-14"}
        rows = self.br.pr_rows({"author": [pr], "reviewer": [], "commenter": [pr]})
        self.assertEqual([(r["url"], r["roles"]) for r in rows], [(pr["url"], ["author", "commenter"])])


class RunLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.br = load_module()
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.vault = base / "brain"
        self.vault.mkdir()
        git(self.vault, "init", "-q")
        (self.vault / "CLAUDE.md").write_text("config\n")
        git(self.vault, "add", "-A")
        git(self.vault, "commit", "-qm", "init")
        self.state = base / "state"
        self.config = self.br.Config(vault=self.vault, state_dir=self.state)
        self.old_env = dict(os.environ)
        os.environ.update({k: v for k, v in ENV.items() if k.startswith("GIT_")})

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.old_env)
        self.tmp.cleanup()

    def write_note(self, rel, text="x\n"):
        path = self.vault / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def commit_notes(self):
        git(self.vault, "add", "-A")
        git(self.vault, "commit", "-qm", "harvest")

    def cursors(self):
        return json.loads((self.state / "cursors.json").read_text())

    def test_begin_refuses_a_dirty_vault(self):
        self.write_note("wiki/half-done.md")
        with self.assertRaisesRegex(self.br.Refused, "wiki/half-done.md"):
            self.br.begin(self.config, at("2026-10-14T17:30:00"), UTC)

    def test_begin_refuses_while_another_run_is_active(self):
        self.br.begin(self.config, at("2026-10-14T17:30:00"), UTC)
        with self.assertRaisesRegex(self.br.Refused, "in progress"):
            self.br.begin(self.config, at("2026-10-14T17:40:00"), UTC)

    def test_a_stale_claim_does_not_block_forever(self):
        self.br.begin(self.config, at("2026-10-14T10:00:00"), UTC)
        run = self.br.begin(self.config, at("2026-10-14T17:30:00"), UTC)
        self.assertTrue(run.nonce)

    def test_first_run_starts_at_the_newest_daily_note(self):
        self.write_note("daily/2026-10-12.md")
        self.commit_notes()
        run = self.br.begin(self.config, at("2026-10-14T17:30:00"), UTC)
        self.assertEqual(run.days, ("2026-10-12", "2026-10-13", "2026-10-14"))

    def test_successful_run_advances_completed_sources_to_its_start(self):
        run = self.br.begin(self.config, at("2026-10-14T17:30:00"), UTC)
        self.write_note("daily/2026-10-14.md")
        self.commit_notes()
        got = self.br.finish(self.config, run.nonce, ["sessions", "chat"])
        self.assertEqual(got["advanced"], ["sessions", "chat"])
        self.assertEqual(self.cursors(), {"sessions": run.started, "chat": run.started})

    def test_a_run_with_nothing_to_commit_still_succeeds(self):
        run = self.br.begin(self.config, at("2026-10-14T17:30:00"), UTC)
        got = self.br.finish(self.config, run.nonce, ["git"])
        self.assertEqual(got["advanced"], ["git"])

    def test_uncommitted_work_advances_nothing_and_releases_the_claim(self):
        run = self.br.begin(self.config, at("2026-10-14T17:30:00"), UTC)
        self.write_note("daily/2026-10-14.md")
        with self.assertRaises(self.br.Refused):
            self.br.finish(self.config, run.nonce, ["chat"])
        self.assertFalse((self.state / "cursors.json").exists())
        self.assertFalse((self.state / "active.json").exists())

    def test_finish_rejects_a_forged_or_spent_nonce(self):
        run = self.br.begin(self.config, at("2026-10-14T17:30:00"), UTC)
        with self.assertRaises(self.br.Refused):
            self.br.finish(self.config, "forged", ["chat"])
        self.br.finish(self.config, run.nonce, [])
        with self.assertRaises(self.br.Refused):
            self.br.finish(self.config, run.nonce, ["chat"])

    def test_finish_rejects_unknown_sources(self):
        run = self.br.begin(self.config, at("2026-10-14T17:30:00"), UTC)
        with self.assertRaisesRegex(self.br.Refused, "bogus"):
            self.br.finish(self.config, run.nonce, ["bogus"])

    def test_rewritten_history_advances_nothing(self):
        run = self.br.begin(self.config, at("2026-10-14T17:30:00"), UTC)
        git(self.vault, "commit", "-q", "--amend", "-m", "rewritten")
        with self.assertRaisesRegex(self.br.Refused, "history"):
            self.br.finish(self.config, run.nonce, ["chat"])
        self.assertFalse((self.state / "cursors.json").exists())

    def test_capped_backlog_advances_to_the_end_of_the_last_rebuilt_day(self):
        self.write_note("daily/2026-10-01.md")
        self.commit_notes()
        run = self.br.begin(self.config, at("2026-10-20T17:30:00"), UTC)
        self.assertTrue(run.truncated)
        self.br.finish(self.config, run.nonce, list(self.br.SOURCES))
        nxt = self.br.begin(self.config, at("2026-10-20T17:31:00"), UTC)
        self.assertEqual(nxt.days[0], "2026-10-06")

    def test_failed_source_is_re_pulled_from_its_old_day(self):
        first = self.br.begin(self.config, at("2026-10-13T17:30:00"), UTC)
        self.br.finish(self.config, first.nonce, list(self.br.SOURCES))
        second = self.br.begin(self.config, at("2026-10-14T17:30:00"), UTC)
        self.br.finish(self.config, second.nonce, [s for s in self.br.SOURCES if s != "mail"])
        third = self.br.begin(self.config, at("2026-10-15T17:30:00"), UTC)
        self.assertEqual(third.days, ("2026-10-13", "2026-10-14", "2026-10-15"))


class CollectTests(unittest.TestCase):
    def setUp(self):
        self.br = load_module()
        self.tmp = tempfile.TemporaryDirectory()
        self.base = Path(self.tmp.name)
        self.run = self.br.Run(
            nonce="n",
            started="2026-10-14T17:30:00+00:00",
            head0="",
            cursors_read={},
            days=("2026-10-14",),
            advance_to="2026-10-14T17:30:00+00:00",
            truncated=False,
        )

    def tearDown(self):
        self.tmp.cleanup()

    def make_repo(self, path, when):
        path.mkdir(parents=True)
        git(path, "init", "-q")
        env = {**ENV, "GIT_COMMITTER_DATE": when, "GIT_AUTHOR_DATE": when}
        (path / "f").write_text("x")
        git(path, "add", "f", env=env)
        git(path, "commit", "-qm", "first change", env=env)
        return path

    def test_git_rows_come_from_every_repo_under_the_roots_once(self):
        root = self.base / "code"
        self.make_repo(root / "owner" / "repo", "2026-10-14T09:00:00+00:00")
        (self.base / "link").symlink_to(root)
        config = self.br.Config(vault=self.base, state_dir=self.base / "s", repo_roots=(root, self.base / "link"))
        rows = self.br.collect(config, self.run, "git", tz=UTC)
        self.assertEqual([(Path(r["repo"]).name, r["subject"]) for r in rows], [("repo", "first change")])

    def test_github_queries_start_at_the_first_rebuilt_day(self):
        calls = []

        def fake_gh(args):
            calls.append(args)
            return "[]"

        self.br.collect(self.br.Config(vault=self.base, state_dir=self.base), self.run, "github", gh=fake_gh)
        self.assertEqual(len(calls), 3)
        self.assertTrue(all("--updated=>=2026-10-14" in c for c in calls))

    def test_connector_sources_are_not_collected_locally(self):
        with self.assertRaises(self.br.Refused):
            self.br.collect(self.br.Config(vault=self.base, state_dir=self.base), self.run, "chat")

    def test_sessions_use_vault_ticket_prefixes_and_exclusions(self):
        vault = self.base / "brain"
        vault.mkdir()
        (vault / "CLAUDE.md").write_text("## Ticket prefixes\nFOO\n")
        projects = self.base / "projects"

        def session(name, cwd, text):
            path = projects / "-p" / f"{name}.jsonl"
            path.parent.mkdir(parents=True, exist_ok=True)
            record = {
                "type": "user",
                "timestamp": "2026-10-14T12:00:00Z",
                "cwd": cwd,
                "message": {"role": "user", "content": text},
            }
            path.write_text(json.dumps(record) + "\n")

        session("mine", "/repo", "work on FOO-1 and BAR-2")
        session("headless", "/state/run", "harvest")
        config = self.br.Config(
            vault=vault, state_dir=self.base / "s", exclude_cwds=("/state/run",), transcripts=projects
        )
        rows = self.br.collect(config, self.run, "sessions")
        self.assertEqual([(r["session_id"], r["tickets"], r["day"]) for r in rows], [("mine", ["FOO-1"], "2026-10-14")])


class CliTests(unittest.TestCase):
    def setUp(self):
        self.br = load_module()
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.vault = base / "brain"
        self.vault.mkdir()
        git(self.vault, "init", "-q")
        git(self.vault, "commit", "-q", "--allow-empty", "-m", "init")
        self.config_path = base / "autopilot.json"
        self.config_path.write_text(json.dumps({"vault": str(self.vault), "state_dir": str(base / "state")}))
        self.old_env = dict(os.environ)
        os.environ.update({k: v for k, v in ENV.items() if k.startswith("GIT_")})

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.old_env)
        self.tmp.cleanup()

    def cli(self, *args):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = self.br.main(["--config", str(self.config_path), *args], now=at("2026-10-14T17:30:00"))
        return code, out.getvalue(), err.getvalue()

    def test_begin_then_finish_round_trip(self):
        code, out, _ = self.cli("begin")
        self.assertEqual(code, 0)
        nonce = json.loads(out)["run"]
        code, out, _ = self.cli("finish", "--run", nonce, "--complete", "chat,git")
        self.assertEqual((code, json.loads(out)["advanced"]), (0, ["git", "chat"]))

    def test_refusals_exit_nonzero_with_a_reason(self):
        code, _, err = self.cli("finish", "--run", "nope")
        self.assertEqual(code, 1)
        self.assertIn("refused", err)


if __name__ == "__main__":
    unittest.main()
