"""Contract tests: every documented sdlc behavior gets a locking test.

The CLI predates the TDD rule; these tests make the coverage prescriptive by
deriving expectations from the README/SKILL contract rather than from the
implementation. Where a test fails against current code, the behavior is
wrong and gets fixed.
"""

import os
import stat
import subprocess
import sys
import tempfile
import unittest

from test_sdlc_flow import CliTest, _git

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "modules", "features", "ai", "sdlc"))

import sdlc_state as store  # noqa: E402

CLI = os.path.join(os.path.dirname(__file__), "..", "modules", "features", "ai", "sdlc", "sdlc_cli.py")


def _write_script(directory, name, source):
    path = os.path.join(directory, name)
    with open(path, "w") as f:
        f.write(source)
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR)
    return path


class ContractCliTest(CliTest):
    """Extends CliTest's git-backed state repo setup."""

    def test_bootstrap_renders_design_and_plan(self):
        key = self._new_feature("boot", ["Research"])
        self.run_cli("task", key, "add", "Implement", "--needs", "T1")
        out = self.run_cli("bootstrap", key)
        self.assertEqual(out.returncode, 0)
        self.assertIn(f"# {key}", out.stdout)
        self.assertIn("## Design doc", out.stdout)
        self.assertIn("## Plan", out.stdout)
        self.assertIn("- [ ] T1 Research", out.stdout)
        self.assertIn("- [ ] T2 Implement (needs: T1)", out.stdout)
        self.assertIn("gates: approved=no", out.stdout)

    def test_bootstrap_reports_plan_problems(self):
        key = self._new_feature("badplan")
        plan_path = os.path.join(self._root, "features", key, "plan.md")
        with open(plan_path, "w") as f:
            f.write("- [ ] T1: t (needs: T9)\n")
        out = self.run_cli("bootstrap", key)
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("plan problems", out.stdout)

    def test_plan_and_status_render_gate_state(self):
        key = self._new_feature("render", ["T"])
        plan = self.run_cli("plan", key)
        self.assertEqual(plan.returncode, 0)
        self.assertIn("tasks: 0/1 done", plan.stdout)
        self.assertIn("gates: approved=no", plan.stdout)
        status = self.run_cli("status", key)
        self.assertEqual(status.returncode, 0)
        self.assertIn("phase: plan review", status.stdout)

    def test_plan_invalid_exits_with_problem(self):
        key = self._new_feature("invalid")
        plan_path = os.path.join(self._root, "features", key, "plan.md")
        with open(plan_path, "w") as f:
            f.write("- [ ] T1: a\n- [ ] T1: b\n")
        out = self.run_cli("plan", key)
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("duplicate task id", out.stderr)

    def test_list_renders_phase_and_claim(self):
        key = self._new_feature("listed", ["T"])
        out = self.run_cli("list")
        self.assertEqual(out.returncode, 0)
        self.assertIn(key, out.stdout)
        self.assertIn("plan review", out.stdout)
        env = dict(self._env)
        env["USER"] = "tester"
        env["LOGNAME"] = "tester"
        subprocess.run(
            [sys.executable, CLI, "claim", key], capture_output=True, text=True, env=env, check=True
        )
        out = self.run_cli("list")
        self.assertIn("tester@", out.stdout)

    def test_next_all_lists_all_workable(self):
        key = self._new_feature("all-next", ["T1", "T2", "T3"])
        self.run_cli("approve", key)
        out = self.run_cli("next", key, "--all")
        self.assertEqual(out.returncode, 0)
        lines = out.stdout.strip().splitlines()
        self.assertEqual(len(lines), 3)
        self.assertIn("T1", lines[0])

    def test_task_done_idempotency_and_cancel_after_done(self):
        key = self._new_feature("idem", ["T1"])
        self.assertEqual(self.run_cli("task", key, "done", "T1").returncode, 0)
        again = self.run_cli("task", key, "done", "T1")
        self.assertNotEqual(again.returncode, 0)
        self.assertIn("already done", again.stderr)
        # cancel of a completed (status=done) feature is refused
        self.run_cli("approve", key)
        self.run_cli("complete", key)
        cancel = self.run_cli("cancel", key)
        self.assertNotEqual(cancel.returncode, 0)
        self.assertIn("already done", cancel.stderr)

    def test_new_validation_errors(self):
        bad_slug = self.run_cli("new", "Bad Slug!", "--repo", "a/b")
        self.assertNotEqual(bad_slug.returncode, 0)
        bad_repo = self.run_cli("new", "ok-slug", "--repo", "not-a-repo")
        self.assertNotEqual(bad_repo.returncode, 0)
        self.run_cli("new", "dup", "--repo", "a/b")
        dup = self.run_cli("new", "dup", "--repo", "a/b")
        self.assertNotEqual(dup.returncode, 0)
        self.assertIn("already exists", dup.stderr)

    def test_approve_refuses_empty_design(self):
        key = self._new_feature("nodesign")
        design = os.path.join(self._root, "features", key, "design.md")
        with open(design, "w") as f:
            f.write("")
        out = self.run_cli("approve", key)
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("design.md is empty", out.stderr)

    def test_complete_guards(self):
        # tasks remaining -> refused
        key = self._new_feature("guard1", ["T1", "T2"])
        self.run_cli("approve", key)
        out = self.run_cli("complete", key)
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("tasks remain", out.stderr)
        # dirty design after approval -> refused until re-approval
        key2 = self._new_feature("guard2", ["T1"])
        self.run_cli("approve", key2)
        design = os.path.join(self._root, "features", key2, "design.md")
        with open(design, "a") as f:
            f.write("\nlate change\n")
        out = self.run_cli("complete", key2)
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("re-approve", out.stderr)
        self.run_cli("approve", key2)
        self.run_cli("task", key2, "done", "T1")
        self.assertEqual(self.run_cli("complete", key2).returncode, 0)

    def test_edit_commits_changes(self):
        key = self._new_feature("edited", ["T1"])
        editor = _write_script(
            self._tmp.name,
            "editor-append.py",
            f"#!{sys.executable}\nimport sys\nopen(sys.argv[1], 'a').write('\\n# edited\\n')\n",
        )
        env = dict(self._env)
        env["EDITOR"] = editor
        out = subprocess.run(
            [sys.executable, os.path.join(os.path.dirname(__file__), "..", "modules", "features", "ai", "sdlc", "sdlc_cli.py"), "edit", key],
            capture_output=True,
            text=True,
            env=env,
        )
        self.assertEqual(out.returncode, 0)
        self.assertIn("design.md updated", out.stdout)
        log = _git(self._root, "log", "--oneline")
        self.assertIn("edit design", log.stdout)

    def test_edit_unchanged_and_editor_failure(self):
        key = self._new_feature("edit2", ["T1"])
        noop = _write_script(self._tmp.name, "editor-noop.py", f"#!{sys.executable}\n")
        fail = _write_script(self._tmp.name, "editor-fail.py", f"#!{sys.executable}\nimport sys\nsys.exit(3)\n")
        for editor, want_rc, want_text in [
            (noop, 0, "doc unchanged"),
            (fail, 1, "editor exited 3"),
        ]:
            env = dict(self._env)
            env["EDITOR"] = editor
            out = subprocess.run(
                [sys.executable, os.path.join(os.path.dirname(__file__), "..", "modules", "features", "ai", "sdlc", "sdlc_cli.py"), "edit", key],
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertEqual(out.returncode, want_rc, out.stderr)
            self.assertIn(want_text, out.stdout + out.stderr)

    def test_symlinked_design_refused(self):
        key = self._new_feature("symdesign")
        design = os.path.join(self._root, "features", key, "design.md")
        target = os.path.join(self._tmp.name, "target.md")
        with open(target, "w") as f:
            f.write("secret")
        os.unlink(design)
        os.symlink(target, design)
        out = self.run_cli("status", key)
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("symlink", out.stderr)

    def _new_feature(self, slug, task_titles=()):
        self.assertEqual(self.run_cli("new", slug, "--repo", "a/b").returncode, 0)
        key = f"a--b--{slug}"
        for title in task_titles:
            self.assertEqual(self.run_cli("task", key, "add", title).returncode, 0)
        return key


class StoreContractTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self._root = os.path.join(self._tmp.name, "state")
        os.makedirs(self._root)
        _git(self._root, "init", "-q")
        _git(self._root, "config", "user.email", "t@t")
        _git(self._root, "config", "user.name", "t")
        self._env = os.environ.copy()

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self._env)
        self._tmp.cleanup()

    def test_push_failure_exits_and_sanitizes(self):
        _git(self._root, "remote", "add", "origin", "file:///nonexistent/sdlc-state.git")
        with self.assertRaises(SystemExit):
            store.create(self._root, "a--b--pushfail", "a/b", "X")
        # no SDLC_NO_PUSH: the mutation committed locally then push failed loudly
        log = _git(self._root, "log", "--oneline")
        self.assertIn("create feature", log.stdout)

    def test_sanitize_url_strips_credentials(self):
        from sdlc_state import _sanitize_url

        dirty = "fatal: unable to access 'https://user:sekret@github.com/smores56/sdlc-state.git/': 403"
        clean = _sanitize_url(dirty)
        self.assertNotIn("sekret", clean)
        self.assertIn("https://***@github.com/smores56/sdlc-state.git", clean)


if __name__ == "__main__":
    unittest.main()
