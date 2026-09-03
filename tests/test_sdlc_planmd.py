"""Contract-first tests for the plan.md source-of-truth redesign.

New behaviors under test (written before implementation):
- parse_plan: grammar, free-text tolerance, malformed lines, (canceled),
  (needs: ...), empty titles, file order preserved
- task line ops: done/cancel/add rewrite only the task's line, preserving
  surrounding prose and markers
- open markers surfaced by bootstrap
"""

import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "modules", "features", "ai", "sdlc"))

import sdlc_model  # noqa: E402
import sdlc_state as store  # noqa: E402

from test_sdlc_flow import CliTest, _git  # noqa: E402

sys.path.insert(0, os.path.dirname(__file__))


class PlanParseTest(unittest.TestCase):
    def parse(self, text):
        return sdlc_model.parse_plan(text)

    def test_parses_tasks_in_file_order(self):
        text = "# Plan\n\n- [ ] T1: Research API\n- [x] T2: Implement (needs: T1)\n"
        tasks, problems, _ = self.parse(text)
        self.assertEqual(problems, [])
        self.assertEqual([t["id"] for t in tasks], ["T1", "T2"])
        self.assertEqual(tasks[0]["status"], "todo")
        self.assertEqual(tasks[1]["status"], "done")
        self.assertEqual(tasks[1]["needs"], ["T1"])

    def test_canceled_tag(self):
        text = "- [x] T1: Abandoned idea (canceled)\n"
        tasks, problems, _ = self.parse(text)
        self.assertEqual(problems, [])
        self.assertEqual(tasks[0]["status"], "canceled")

    def test_free_text_and_markers_ignored(self):
        text = (
            "# Plan\n\n"
            "> Sam: fold T3 into T2\n\n"
            "- [ ] T1: Real task\n\n"
            "some prose between tasks\n\n"
            "- [x] T2: Second (canceled)\n"
        )
        tasks, problems, _ = self.parse(text)
        self.assertEqual(problems, [])
        self.assertEqual([t["id"] for t in tasks], ["T1", "T2"])
        self.assertEqual(tasks[1]["status"], "canceled")

    def test_multiple_needs_and_needs_canceled_order(self):
        text = "- [x] T3: Ship (needs: T1, T2) (canceled)\n"
        tasks, problems, _ = self.parse(text)
        self.assertEqual(problems, [])
        self.assertEqual(tasks[0]["needs"], ["T1", "T2"])
        self.assertEqual(tasks[0]["status"], "canceled")

    def test_malformed_task_line_reports_line(self):
        text = "- [ ] T1: fine\n- [ ] not-a-task\n- [ ] T2\n- [x] notanumber: nope\n"
        tasks, problems, _ = self.parse(text)
        self.assertEqual([t["id"] for t in tasks], ["T1"])
        line_numbers = [int(p.split("line")[1].split(":")[0].strip()) for p in problems]
        self.assertIn(2, line_numbers)
        self.assertIn(3, line_numbers)
        self.assertIn(4, line_numbers)

    def test_needs_reference_normalized_and_validated(self):
        text = "- [ ] T1: A (needs: t2)\n- [ ] T2: B\n"
        tasks, problems, _ = self.parse(text)
        self.assertEqual(tasks[0]["needs"], ["T2"])
        self.assertEqual(sdlc_model.validate_tasks(tasks), [])

    def test_empty_title_is_problem(self):
        text = "- [ ] T1:   \n"
        tasks, problems, _ = self.parse(text)
        self.assertEqual(tasks, [])
        self.assertTrue(problems)

    def test_task_line_roundtrip(self):
        task = {"id": "T1", "title": "Do the thing", "status": "todo", "needs": ["T2"]}
        line = sdlc_model.task_line(task)
        self.assertEqual(line, "- [ ] T1: Do the thing (needs: T2)")
        task["status"] = "canceled"
        self.assertEqual(sdlc_model.task_line(task), "- [x] T1: Do the thing (needs: T2) (canceled)")

    def test_replace_task_line_preserves_rest(self):
        lines = [
            "# Plan",
            "",
            "> Sam: review T2",
            "- [ ] T1: First",
            "- [ ] T2: Second (needs: T1)",
            "",
            "note at the end",
        ]
        out = sdlc_model.replace_task_line(lines, "T1", {"id": "T1", "title": "First!", "status": "done", "needs": []})
        self.assertEqual(out[3], "- [x] T1: First!")
        self.assertEqual(out[2], "> Sam: review T2")
        self.assertEqual(out[6], "note at the end")

    def test_open_markers(self):
        text = "design\n> Sam: is this the right model?\nplain\n> Someone else: not a marker\n> Sam: second\n"
        self.assertEqual(
            sdlc_model.open_markers(text),
            ["is this the right model?", "second"],
        )


class PlanStoreTest(unittest.TestCase):
    def setUp(self):
        import tempfile

        self._tmp = tempfile.TemporaryDirectory()
        self._root = os.path.join(self._tmp.name, "state")
        os.makedirs(self._root)
        _git(self._root, "init", "-q")
        _git(self._root, "config", "user.email", "t@t")
        _git(self._root, "config", "user.name", "t")
        self._env = os.environ.copy()
        os.environ["SDLC_STATE_DIR"] = self._root
        os.environ["SDLC_NO_PUSH"] = "1"

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self._env)
        self._tmp.cleanup()

    def test_create_seeds_plan_and_meta_only_json(self):
        store.create(self._root, "a--b--x", "a/b", "X")
        plan = open(store.plan_path(self._root, "a--b--x")).read()
        self.assertTrue(plan.startswith("# Plan"))
        raw = json.load(open(os.path.join(self._root, "features", "a--b--x", "state.json")))
        self.assertNotIn("tasks", raw)

    def test_load_ignores_legacy_tasks_and_reads_plan(self):
        store.create(self._root, "a--b--x", "a/b", "X")
        state_path = os.path.join(self._root, "features", "a--b--x", "state.json")
        raw = json.load(open(state_path))
        raw["tasks"] = [{"id": "T1", "title": "legacy", "status": "todo", "needs": []}]
        with open(state_path, "w") as f:
            json.dump(raw, f)
        state = store.load(self._root, "a--b--x")
        self.assertNotIn("tasks", state)
        tasks, _, _ = sdlc_model.parse_plan(state["plan"])
        self.assertEqual(tasks, [])

    def test_write_plan_commits(self):
        store.create(self._root, "a--b--x", "a/b", "X")
        store.write_plan(self._root, "a--b--x", "# Plan\n\n- [ ] T1: New task\n")
        tasks, problems, _ = sdlc_model.parse_plan(store.load(self._root, "a--b--x")["plan"])
        self.assertEqual(problems, [])
        self.assertEqual(tasks[0]["id"], "T1")
        log = _git(self._root, "log", "--oneline")
        self.assertIn("update plan", log.stdout)


class PlanCliTest(CliTest):
    def _write_editor(self, name, body):
        import stat

        path = os.path.join(self._tmp.name, name)
        with open(path, "w") as f:
            f.write(f"#!{sys.executable}\n{body}")
        os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR)
        return path

    def test_edit_plan_validates_and_fails_on_invalid(self):
        key = self._new_feature("editplan", ["T1"])
        editor = self._write_editor(
            "editor-invalid.py",
            "import sys\nopen(sys.argv[1], 'w').write('- [ ] T1: broken needs (needs: T9)\\n')\n",
        )
        env = dict(self._env)
        env["EDITOR"] = editor
        out = self._run_edit(env, key, "plan")
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("unknown need", out.stderr)

    def test_edit_plan_valid_succeeds(self):
        key = self._new_feature("okplan", ["T1"])
        editor = self._write_editor(
            "editor-valid.py",
            "import sys\nopen(sys.argv[1], 'w').write('# Plan\\n\\n- [ ] T1: fine\\n')\n",
        )
        env = dict(self._env)
        env["EDITOR"] = editor
        out = self._run_edit(env, key, "plan")
        self.assertEqual(out.returncode, 0, out.stderr)

    def test_path_prints_doc_paths(self):
        key = self._new_feature("paths")
        both = self.run_cli("path", key)
        self.assertEqual(both.returncode, 0)
        self.assertIn("design.md", both.stdout)
        self.assertIn("plan.md", both.stdout)
        design = self.run_cli("path", key, "design")
        self.assertIn("design.md", design.stdout)
        self.assertNotIn("plan.md", design.stdout)

    def test_bootstrap_lists_open_markers(self):
        key = self._new_feature("marked", ["T1"])
        design = os.path.join(self._root, "features", key, "design.md")
        with open(design, "a") as f:
            f.write("\n> Sam: should we use the cache?\n")
        out = self.run_cli("bootstrap", key)
        self.assertEqual(out.returncode, 0)
        self.assertIn("should we use the cache?", out.stdout)

    def test_task_ops_preserve_markers(self):
        key = self._new_feature("preserve", ["T1"])
        plan = os.path.join(self._root, "features", key, "plan.md")
        with open(plan, "a") as f:
            f.write("> Sam: revisit sizing later\n")
        self.run_cli("task", key, "add", "Second")
        self.run_cli("task", key, "done", "T1")
        text = open(plan).read()
        self.assertIn("> Sam: revisit sizing later", text)
        self.assertIn("- [x] T1:", text)
        tasks, problems, _ = sdlc_model.parse_plan(text)
        self.assertEqual(problems, [])
        self.assertEqual(len(tasks), 2)

    def test_task_ops_leave_trailing_newline(self):
        key = self._new_feature("newline", ["T1"])
        plan = os.path.join(self._root, "features", key, "plan.md")
        self.run_cli("task", key, "add", "Second")
        text = open(plan).read()
        self.assertTrue(text.endswith("\n"), repr(text[-20:]))
        self.run_cli("task", key, "done", "T1")
        self.assertTrue(open(plan).read().endswith("\n"))

    # helpers
    def _new_feature(self, slug, titles=()):
        self.assertEqual(self.run_cli("new", slug, "--repo", "a/b").returncode, 0)
        key = f"a--b--{slug}"
        for title in titles:
            self.run_cli("task", key, "add", title)
        return key

    def _noop_editor(self):
        import stat

        path = os.path.join(self._tmp.name, "editor-noop.py")
        with open(path, "w") as f:
            f.write(f"#!{sys.executable}\n")
        os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR)
        return path

    def _run_edit(self, env, key, doc):
        import subprocess

        return subprocess.run(
            [sys.executable, os.path.join(os.path.dirname(__file__), "..", "modules", "features", "ai", "sdlc", "sdlc_cli.py"), "edit", key, doc],
            capture_output=True,
            text=True,
            env=env,
        )


if __name__ == "__main__":
    unittest.main()
