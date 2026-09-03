import json
import os
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "modules", "features", "ai", "sdlc"))

import sdlc_model  # noqa: E402
import sdlc_state as store  # noqa: E402

CLI = os.path.join(os.path.dirname(__file__), "..", "modules", "features", "ai", "sdlc", "sdlc_cli.py")


def task(tid, needs=(), status="todo"):
    return {"id": tid, "title": tid, "status": status, "needs": list(needs)}


class ModelTest(unittest.TestCase):
    def test_workable_respects_needs(self):
        tasks = [task("T1"), task("T2", needs=["T1"]), task("T3")]
        self.assertEqual([t["id"] for t in sdlc_model.workable(tasks)], ["T1", "T3"])

    def test_workable_after_done(self):
        tasks = [task("T1", status="done"), task("T2", needs=["T1"]), task("T3", needs=["T1"])]
        self.assertEqual([t["id"] for t in sdlc_model.workable(tasks)], ["T2", "T3"])

    def test_cycle_detected(self):
        tasks = [task("T1", needs=["T2"]), task("T2", needs=["T1"])]
        self.assertTrue(sdlc_model.has_cycle(tasks))
        self.assertIn("dependency cycle", sdlc_model.validate_tasks(tasks))

    def test_self_cycle_detected(self):
        tasks = [task("T1", needs=["T1"])]
        self.assertTrue(sdlc_model.has_cycle(tasks))

    def test_acyclic_chain_valid(self):
        tasks = [task("T1"), task("T2", needs=["T1"]), task("T3", needs=["T2"])]
        self.assertFalse(sdlc_model.has_cycle(tasks))
        self.assertEqual(sdlc_model.validate_tasks(tasks), [])

    def test_validate_is_order_independent(self):
        # needs may reference tasks listed later
        tasks = [task("T2", needs=["T1"]), task("T1")]
        self.assertEqual(sdlc_model.validate_tasks(tasks), [])
        tasks = [task("T3", needs=["T2"]), task("T2", needs=["T1"]), task("T1")]
        self.assertEqual(sdlc_model.validate_tasks(tasks), [])
        # a forward-edge cycle is still caught
        cycle = [task("T1", needs=["T2"]), task("T2", needs=["T3"]), task("T3", needs=["T1"])]
        self.assertIn("dependency cycle", sdlc_model.validate_tasks(cycle))

    def test_validate_unknown_need_and_duplicate(self):
        tasks = [task("T1"), task("T1"), task("T2", needs=["T9"])]
        problems = sdlc_model.validate_tasks(tasks)
        self.assertIn("duplicate task id: T1", problems)
        self.assertIn("T2: unknown need 'T9'", problems)

    def test_phases(self):
        base = {"status": "active", "approval": None, "tasks": []}
        self.assertEqual(sdlc_model.phase(base), "design")
        base["tasks"] = [task("T1")]
        self.assertEqual(sdlc_model.phase(base), "plan review")
        base["approval"] = {"design_sha": "x"}
        self.assertEqual(sdlc_model.phase(base), "building")
        base["tasks"][0]["status"] = "done"
        self.assertEqual(sdlc_model.phase(base), "finishing")
        base["status"] = "done"
        self.assertEqual(sdlc_model.phase(base), "done")

    def test_design_diff(self):
        sha = sdlc_model.design_sha("same")
        feature = {"approval": {"design_sha": sha}, "design": "same"}
        self.assertIsNone(sdlc_model.design_diff(feature))
        feature["design"] = "changed"
        self.assertEqual(sdlc_model.design_diff(feature), sha)
        self.assertIsNone(sdlc_model.design_diff({"approval": None, "design": "changed"}))

    def test_gate_status(self):
        feature = {"status": "active", "approval": None, "design": ""}
        self.assertEqual(sdlc_model.gate_status(feature)["approved"], False)
        feature["approval"] = {"design_sha": sdlc_model.design_sha("")}
        self.assertEqual(sdlc_model.gate_status(feature)["design_changed"], False)
        feature["status"] = "done"
        self.assertEqual(sdlc_model.gate_status(feature)["active"], False)

    def test_design_sha_stable(self):
        self.assertEqual(sdlc_model.design_sha("hi"), sdlc_model.design_sha("hi"))
        self.assertNotEqual(sdlc_model.design_sha("hi"), sdlc_model.design_sha("hi "))

    def test_clean_strips_control_chars(self):
        self.assertEqual(sdlc_model.clean("a\x1b[31mb\x00c"), "a[31mbc")
        self.assertEqual(sdlc_model.clean("plain"), "plain")

    def test_render_contains_edges_and_scrubs(self):
        tasks = [task("T1"), task("T2", needs=["T1"])]
        out = sdlc_model.render_tasks(tasks)
        self.assertIn("- [ ] T1 T1", out[0])
        self.assertIn("needs: T1", out[1])


class StoreTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self._root = os.path.join(self._tmp.name, "state")
        os.makedirs(self._root)
        self._env = os.environ.copy()
        os.environ["SDLC_STATE_DIR"] = self._root
        os.environ["SDLC_NO_PUSH"] = "1"

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self._env)
        self._tmp.cleanup()

    def test_create_list_load(self):
        key = "smores56--nix-config--demo"
        store.create(self._root, key, "smores56/nix-config", "Demo")
        self.assertEqual(store.list_keys(self._root), [key])
        state = store.load(self._root, key)
        self.assertEqual(state["repo"], "smores56/nix-config")
        self.assertEqual(state["status"], "active")
        self.assertEqual(state["plan"], "# Plan\n\n")
        self.assertEqual(state["design"], "# Demo\n\n")
        self.assertIsNone(state["approval"])
        # no git repo in the tempdir: mutations must not raise
        store.write_plan(self._root, key, "# Plan\n\n- [ ] T1: t\n")
        tasks, _, _ = sdlc_model.parse_plan(store.load(self._root, key)["plan"])
        self.assertEqual(tasks[0]["id"], "T1")

    def test_design_roundtrip_and_sha_gate(self):
        key = "smores56--nix-config--demo"
        store.create(self._root, key, "smores56/nix-config", "Demo")
        store.write_design(self._root, key, "# Design\nv1\n")
        content = open(store.design_path(self._root, key)).read()
        self.assertEqual(content, "# Design\nv1\n")
        sha1 = sdlc_model.design_sha(content)
        state = store.load(self._root, key)
        state["approval"] = {"design_sha": sha1}
        store.save(self._root, key, state)
        self.assertIsNone(sdlc_model.design_diff(store.load(self._root, key)))
        store.write_design(self._root, key, "# Design\nv2\n")
        self.assertIsNotNone(sdlc_model.design_diff(store.load(self._root, key)))

    def test_resolve_slug(self):
        store.create(self._root, "a--b--one", "a/b", "One")
        store.create(self._root, "c--d--two", "c/d", "Two")
        self.assertEqual(store.resolve(self._root, "one"), "a--b--one")
        with self.assertRaises(SystemExit):
            store.resolve(self._root, "missing")

    def test_ambiguous_slug_exits(self):
        store.create(self._root, "a--b--same", "a/b", "One")
        store.create(self._root, "c--d--same", "c/d", "Two")
        with self.assertRaises(SystemExit):
            store.resolve(self._root, "same")

    def test_task_ids_assign(self):
        feature = {"tasks": [{"id": "T1"}, {"id": "T2"}]}
        self.assertEqual(store.task_ids(feature), "T3")

    def test_git_commit_happens_in_repo(self):
        subprocess.run(["git", "init", "-q", self._root], check=True)
        subprocess.run(["git", "-C", self._root, "config", "user.email", "t@t"], check=True)
        subprocess.run(["git", "-C", self._root, "config", "user.name", "t"], check=True)
        store.create(self._root, "a--b--x", "a/b", "X")
        log = subprocess.run(
            ["git", "-C", self._root, "log", "--oneline"], capture_output=True, text=True, check=True
        )
        self.assertIn("create feature", log.stdout)

    def test_state_json_is_clean(self):
        key = "a--b--clean"
        store.create(self._root, key, "a/b", "Clean")
        raw = json.load(open(os.path.join(self._root, "features", key, "state.json")))
        self.assertNotIn("design", raw)
        self.assertNotIn("key", raw)

    def test_symlinked_state_refused(self):
        key = "a--b--evil"
        store.create(self._root, key, "a/b", "Evil")
        state_path = os.path.join(self._root, "features", key, "state.json")
        target = os.path.join(self._tmp.name, "target.json")
        with open(target, "w") as f:
            f.write("{}")
        os.unlink(state_path)
        os.symlink(target, state_path)
        with self.assertRaises(SystemExit):
            store.load(self._root, key)
        self.assertEqual(open(target).read(), "{}")


def _git(root, *args):
    return subprocess.run(["git", "-C", root, *args], capture_output=True, text=True, check=True)


class CliTest(unittest.TestCase):
    """End-to-end CLI tests over a real (push-disabled) state repo."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self._root = os.path.join(self._tmp.name, "state")
        os.makedirs(self._root)
        _git(self._root, "init", "-q")
        _git(self._root, "config", "user.email", "t@t")
        _git(self._root, "config", "user.name", "t")
        _git(self._root, "remote", "add", "origin", "git@github.com:smores56/sdlc-state.git")
        self._env = os.environ.copy()
        self._env["SDLC_STATE_DIR"] = self._root
        self._env["SDLC_NO_PUSH"] = "1"
        self._saved_env = os.environ.copy()
        os.environ["SDLC_STATE_DIR"] = self._root
        os.environ["SDLC_NO_PUSH"] = "1"

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self._saved_env)
        self._tmp.cleanup()

    def run_cli(self, *args):
        return subprocess.run(
            [sys.executable, CLI, *args], capture_output=True, text=True, env=self._env
        )

    def test_full_gate_lifecycle(self):
        self.assertEqual(self.run_cli("new", "gate-life", "--repo", "a/b").returncode, 0)
        key = "a--b--gate-life"
        self.assertEqual(self.run_cli("task", key, "add", "Research").returncode, 0)
        self.assertEqual(self.run_cli("task", key, "add", "Implement", "--needs", "T1").returncode, 0)
        # not approved -> next refuses
        refused = self.run_cli("next", key)
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("not approved", refused.stderr)
        self.assertEqual(self.run_cli("approve", key).returncode, 0)
        self.assertEqual(self.run_cli("next", key).returncode, 0)
        # direct design edit after approval -> unapproved-diff blocks next
        design = os.path.join(self._root, "features", key, "design.md")
        with open(design, "a") as f:
            f.write("\nchanged after approval\n")
        blocked = self.run_cli("next", key)
        self.assertNotEqual(blocked.returncode, 0)
        self.assertIn("unapproved-diff", blocked.stderr)
        # re-approve unblocks
        self.assertEqual(self.run_cli("approve", key).returncode, 0)
        self.assertEqual(self.run_cli("next", key).returncode, 0)
        self.assertEqual(self.run_cli("task", key, "done", "T1").returncode, 0)
        self.assertEqual(self.run_cli("task", key, "done", "T2").returncode, 0)
        self.assertEqual(self.run_cli("complete", key).returncode, 0)
        # terminal feature refuses mutations
        self.assertNotEqual(self.run_cli("task", key, "add", "Late").returncode, 0)

    def test_complete_requires_approval_and_tasks(self):
        self.assertEqual(self.run_cli("new", "empty", "--repo", "a/b").returncode, 0)
        key = "a--b--empty"
        denied = self.run_cli("complete", key)
        self.assertNotEqual(denied.returncode, 0)
        self.assertIn("nothing to complete", denied.stderr)
        # with tasks but no approval: still refused
        self.assertEqual(self.run_cli("task", key, "add", "T").returncode, 0)
        self.assertEqual(self.run_cli("task", key, "done", "T1").returncode, 0)
        denied = self.run_cli("complete", key)
        self.assertNotEqual(denied.returncode, 0)
        self.assertIn("not approved", denied.stderr)

    def test_claim_blocks_other_sessions(self):
        self.assertEqual(self.run_cli("new", "claimed", "--repo", "a/b").returncode, 0)
        key = "a--b--claimed"
        self.assertEqual(self.run_cli("claim", key).returncode, 0)
        # simulate another machine's claim
        state_path = os.path.join(self._root, "features", key, "state.json")
        state = json.load(open(state_path))
        state["claim"] = {"by": "someone@elsewhere", "at": "now"}
        with open(state_path, "w") as f:
            json.dump(state, f)
        denied = self.run_cli("task", key, "add", "Sneak")
        self.assertNotEqual(denied.returncode, 0)
        self.assertIn("claimed by someone@elsewhere", denied.stderr)
        released = self.run_cli("claim", key, "--release")
        self.assertNotEqual(released.returncode, 0)
        self.assertIn("only the claimer", released.stderr)

    def test_wrong_origin_refused(self):
        other = os.path.join(self._tmp.name, "other")
        os.makedirs(other)
        _git(other, "init", "-q")
        _git(other, "remote", "add", "origin", "git@github.com:someone/else.git")
        env = os.environ.copy()
        env["SDLC_STATE_DIR"] = other
        env["SDLC_NO_PUSH"] = "1"
        proc = subprocess.run(
            [sys.executable, CLI, "list"], capture_output=True, text=True, env=env
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("refusing", proc.stderr)

    def test_cancel_then_mutate_refused(self):
        self.assertEqual(self.run_cli("new", "cancelled", "--repo", "a/b").returncode, 0)
        key = "a--b--cancelled"
        self.assertEqual(self.run_cli("cancel", key).returncode, 0)
        self.assertNotEqual(self.run_cli("task", key, "add", "Late").returncode, 0)
        self.assertNotEqual(self.run_cli("cancel", key).returncode, 0)


if __name__ == "__main__":
    unittest.main()
