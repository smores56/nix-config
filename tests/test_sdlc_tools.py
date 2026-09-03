"""Tests for the deferred sdlc tooling: diff, list filters, sync, prune.

Written before implementation (red first): the behaviors here are new.
"""

import os
import shutil
import subprocess
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "modules", "features", "ai", "sdlc"))
sys.path.insert(0, os.path.dirname(__file__))

import sdlc_model  # noqa: E402
import sdlc_state as store  # noqa: E402

from test_sdlc_flow import CliTest, _git  # noqa: E402


class ToolCliTest(CliTest):
    def test_list_all_and_status_filter(self):
        done_key = self._new_feature("done1", ["T1"])
        self._finish(done_key)
        cancel_key = self._new_feature("cancel1")
        self.run_cli("cancel", cancel_key)
        active_key = self._new_feature("active1", ["T1"])

        default = self.run_cli("list")
        self.assertIn(active_key, default.stdout)
        self.assertNotIn(done_key, default.stdout)
        self.assertNotIn(cancel_key, default.stdout)

        all_out = self.run_cli("list", "--all")
        for key in (active_key, done_key, cancel_key):
            self.assertIn(key, all_out.stdout)

        done_out = self.run_cli("list", "--status", "done")
        self.assertIn(done_key, done_out.stdout)
        self.assertNotIn(active_key, done_out.stdout)
        canceled_out = self.run_cli("list", "--status", "canceled")
        self.assertIn(cancel_key, canceled_out.stdout)

    def test_list_repo_filter_and_path_format(self):
        self._new_feature("repof1", ["T1"], repo="alpha/beta")
        self._new_feature("repof2", ["T1"], repo="gamma/delta")
        out = self.run_cli("list", "--repo", "alpha/beta")
        self.assertIn("alpha--beta--repof1", out.stdout)
        self.assertNotIn("gamma--delta--repof2", out.stdout)
        path_out = self.run_cli("list", "--path")
        first = path_out.stdout.strip().splitlines()[0].split("\t")
        self.assertEqual(len(first), 3)
        self.assertTrue(first[0].endswith("features/alpha--beta--repof1"))
        self.assertEqual(first[1], "alpha--beta--repof1")
        self.assertEqual(first[2], "plan review")

    def test_diff_requires_approval(self):
        key = self._new_feature("nodiff", ["T1"])
        out = self.run_cli("diff", key)
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("not approved", out.stderr)

    def test_diff_unchanged_after_approval(self):
        key = self._new_feature("samdiff", ["T1"])
        self.run_cli("approve", key)
        out = self.run_cli("diff", key)
        self.assertEqual(out.returncode, 0)
        self.assertIn("no changes since approval", out.stdout)

    def test_diff_shows_design_changes_since_approval(self):
        key = self._new_feature("changediff", ["T1"])
        self.run_cli("approve", key)
        store.write_design(self._root, key, "# Title\n\nnow with more detail\n")
        out = self.run_cli("diff", key)
        self.assertEqual(out.returncode, 0)
        self.assertIn("more detail", out.stdout)

    def test_sync_pulls_remote_commits(self):
        # a committed feature so the local repo has history to seed the bare
        key = self._new_feature("synced", ["T1"])
        bare = os.path.join(self._tmp.name, "smores56", "sdlc-state.git")
        os.makedirs(os.path.dirname(bare))
        subprocess.run(["git", "init", "-q", "--bare", bare], check=True)
        _git(self._root, "remote", "set-url", "origin", f"file://{bare}")
        _git(self._root, "branch", "-M", "main")
        _git(self._root, "push", "-q", "origin", "main")
        # another machine clones and pushes a change
        other = os.path.join(self._tmp.name, "other")
        _git(bare, "clone", "-q", "-b", "main", bare, other)
        _git(other, "config", "user.email", "t@t")
        _git(other, "config", "user.name", "t")
        with open(os.path.join(other, "remote.md"), "w") as f:
            f.write("from another machine\n")
        _git(other, "add", "-A")
        _git(other, "commit", "-q", "-m", "remote change")
        push = subprocess.run(
            ["git", "-C", other, "push", "-q", "origin", "main"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(push.returncode, 0, push.stderr)
        env = dict(self._env)
        env.pop("SDLC_NO_PUSH", None)
        proc = subprocess.run(
            [sys.executable, os.path.join(os.path.dirname(__file__), "..", "modules", "features", "ai", "sdlc", "sdlc_cli.py"), "sync"],
            capture_output=True,
            text=True,
            env=env,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("synced", proc.stdout)
        self.assertTrue(os.path.exists(os.path.join(self._root, "remote.md")))

    def test_prune_removes_terminal_feature(self):
        done_key = self._new_feature("pruned", ["T1"])
        self._finish(done_key)
        out = self.run_cli("prune", done_key)
        self.assertEqual(out.returncode, 0)
        self.assertFalse(os.path.exists(os.path.join(self._root, "features", done_key)))
        log = _git(self._root, "log", "--oneline")
        self.assertIn("prune", log.stdout)
        self.assertNotIn(done_key, self.run_cli("list", "--all").stdout)

    def test_prune_refuses_active_feature(self):
        key = self._new_feature("keepme", ["T1"])
        out = self.run_cli("prune", key)
        self.assertNotEqual(out.returncode, 0)
        self.assertTrue(os.path.exists(os.path.join(self._root, "features", key)))

    # helpers
    def _new_feature(self, slug, titles=(), repo="a/b"):
        self.assertEqual(self.run_cli("new", slug, "--repo", repo).returncode, 0)
        key = f"{repo.replace('/', '--')}--{slug}"
        for title in titles:
            self.run_cli("task", key, "add", title)
        return key

    def _finish(self, key):
        self.run_cli("approve", key)
        tasks, _, _ = sdlc_model.parse_plan(store.load(self._root, key)["plan"])
        for t in tasks:
            self.run_cli("task", key, "done", t["id"])
        self.assertEqual(self.run_cli("complete", key).returncode, 0)


if __name__ == "__main__":
    unittest.main()
