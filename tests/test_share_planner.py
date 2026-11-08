import importlib.util
import io
import os
import socket
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path


def load_module():
    path = Path(__file__).parents[1] / "modules/lib/share_planner.py"
    spec = importlib.util.spec_from_file_location("share_planner", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class SharePlannerTests(unittest.TestCase):
    def setUp(self):
        self.sp = load_module()
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)
        for d in [
            "repos/proj",
            "wip",
            "Blitzy/repo",
            "Library/Keychains",
            "notes",
            ".agents/skills",
            ".config/maki",
            ".config/git",
            ".config/gcloud",
            ".config/gh",
            ".local/bin",
            ".local/state/maki/sessions",
            ".local/logs/maki",
        ]:
            (self.home / d).mkdir(parents=True)
        (self.home / ".gitignore").write_text("node_modules\n")
        (self.home / ".config/maki/init.lua").write_text("-- maki")
        (self.home / ".config/sops").mkdir()
        (self.home / ".config/sops/key").write_text("secret")
        (self.home / ".config/loose.toml").write_text("x")
        (self.home / ".zsh_history").write_text("ls")
        (self.home / ".zshrc").symlink_to("/nix/store/abc-zshrc")

    def tearDown(self):
        self.tmp.cleanup()

    def plan(self, allow=("repos", ".agents", ".local/bin"), allow_rw=("wip",)):
        return self.sp.plan(self.home, list(allow), list(allow_rw))

    def shares(self, plan):
        return {s.rel: s.mode for s in plan.shares}

    def test_allow_roots_are_read_only_and_allow_rw_roots_are_read_write(self):
        shares = self.shares(self.plan())
        self.assertEqual(shares["repos"], "ro")
        self.assertEqual(shares[".agents"], "ro")
        self.assertEqual(shares[".local/bin"], "ro")
        self.assertEqual(shares["wip"], "rw")

    def test_nothing_outside_the_allowlist_is_shared(self):
        plan = self.plan()
        rels = [s.rel for s in plan.shares] + list(plan.copies)
        for rel in ["notes", "Library", "Library/Keychains", ".zsh_history", ".config", ".config/gh"]:
            self.assertNotIn(rel, rels)

    def test_intermediate_ancestors_are_not_themselves_shared(self):
        shares = self.shares(self.plan(allow=(".local/state/maki",), allow_rw=()))
        self.assertEqual(shares, {".local/state/maki": "ro"})

    def test_nested_root_with_the_same_mode_is_deduped_to_its_ancestor(self):
        shares = self.shares(self.plan(allow=(".config", ".config/git"), allow_rw=()))
        self.assertEqual(shares, {".config": "ro"})

    def test_nested_root_with_the_other_mode_splits_its_parent(self):
        shares = self.shares(self.plan(allow=(".config",), allow_rw=(".config/gcloud",)))
        self.assertNotIn(".config", shares)
        self.assertEqual(shares[".config/gcloud"], "rw")
        self.assertEqual(shares[".config/git"], "ro")
        self.assertEqual(shares[".config/maki"], "ro")
        # Inside a read-only allow root, a directory file also stays read-only.
        self.assertEqual(shares[".config/gh"], "ro")

    def test_plain_file_root_becomes_a_copy(self):
        plan = self.plan(allow=(".gitignore",), allow_rw=())
        self.assertEqual(plan.copies, [".gitignore"])
        self.assertEqual(plan.shares, [])

    def test_symlink_root_fails_closed(self):
        with self.assertRaises(self.sp.PlanError):
            self.plan(allow=(".zshrc",), allow_rw=())

    def test_symlink_on_the_way_to_a_root_fails_closed(self):
        (self.home / ".config/linked").symlink_to("/nix/store/abc-config")
        with self.assertRaises(self.sp.PlanError):
            self.plan(allow=(".config/linked/maki",), allow_rw=())

    def test_symlink_outside_the_allowlist_is_ignored(self):
        self.assertNotIn(".zshrc", [s.rel for s in self.plan().shares])

    def test_missing_root_is_skipped_with_a_warning(self):
        stderr = io.StringIO()
        with redirect_stderr(stderr):
            plan = self.plan(allow=("does/not/exist", "repos"), allow_rw=())
        self.assertEqual(self.shares(plan), {"repos": "ro"})
        self.assertIn("does/not/exist", stderr.getvalue())

    def test_unreadable_directory_is_skipped_not_fatal(self):
        locked = self.home / ".config/locked"
        locked.mkdir()
        (locked / "inner").mkdir()
        os.chmod(locked, 0)
        try:
            plan = self.plan(allow=("notes", ".config/locked/inner"), allow_rw=())
            self.assertEqual(self.shares(plan), {"notes": "ro"})
        finally:
            os.chmod(locked, 0o755)

    def test_sockets_are_skipped(self):
        sock = socket.socket(socket.AF_UNIX)
        path = self.home / "agent.sock"
        sock.bind(str(path))
        try:
            plan = self.plan(allow=("agent.sock",), allow_rw=())
            self.assertEqual(plan.shares, [])
            self.assertEqual(plan.copies, [])
        finally:
            sock.close()

    def test_tags_fit_the_virtio_fs_limit(self):
        deep = self.home / ("x" * 80)
        deep.mkdir()
        for share in self.plan(allow=("x" * 80,)).shares:
            self.assertLessEqual(len(share.tag.encode()), 36, share.tag)

    def test_tags_are_unique_and_safe(self):
        tags = [s.tag for s in self.plan().shares]
        self.assertEqual(len(tags), len(set(tags)))
        for tag in tags:
            self.assertRegex(tag, r"^[A-Za-z0-9_-]+$")

    def test_paths_are_normalized(self):
        plan = self.sp.plan(self.home, ["./repos/", ".config//git"], ["wip/"])
        self.assertEqual(self.shares(plan), {".config/git": "ro", "repos": "ro", "wip": "rw"})

    def test_the_same_path_in_both_lists_is_read_write(self):
        self.assertEqual(self.shares(self.plan(allow=("repos",), allow_rw=("repos",))), {"repos": "rw"})

    def test_symlink_inside_an_allowed_directory_is_part_of_the_share(self):
        (self.home / ".config/git/config").symlink_to("/nix/store/abc-git-config")
        shares = self.shares(self.plan(allow=(".config/git",), allow_rw=()))
        self.assertEqual(shares, {".config/git": "ro"})

    def test_cli_returns_nonzero_on_a_symlink_root(self):
        stderr = io.StringIO()
        with redirect_stderr(stderr):
            rc = self.sp.main(["--home", str(self.home), "--allow", ".zshrc"])
        self.assertEqual(rc, 1)
        self.assertIn(".zshrc", stderr.getvalue())

    def test_cli_accepts_allow_and_allow_rw(self):
        stdout = io.StringIO()
        with redirect_stdout(stdout):
            rc = self.sp.main(["--home", str(self.home), "--allow", "repos", "--allow-rw", "wip"])
        self.assertEqual(rc, 0)
        self.assertIn('"rel": "repos"', stdout.getvalue())
        self.assertIn('"mode": "rw"', stdout.getvalue())


if __name__ == "__main__":
    unittest.main()
