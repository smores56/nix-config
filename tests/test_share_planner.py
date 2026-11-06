import importlib.util
import os
import socket
import tempfile
import unittest
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
            "Blitzy/repo",
            "Library/Keychains",
            ".config/sops",
            ".config/gh",
            ".config/gcloud",
            ".config/git",
            "notes",
        ]:
            (self.home / d).mkdir(parents=True)
        (self.home / ".config/sops/key").write_text("secret")
        (self.home / ".config/loose.toml").write_text("x")
        (self.home / ".zsh_history").write_text("ls")
        (self.home / ".zshrc").symlink_to("/nix/store/abc-zshrc")
        (self.home / ".nix-profile").symlink_to("/nix/var/nix/profiles/per-user/sam/profile")

    def tearDown(self):
        self.tmp.cleanup()

    def plan(self, deny=("Library", ".config/sops"), rw=("Blitzy", ".config/gcloud")):
        return self.sp.plan(self.home, list(deny), list(rw))

    def shares(self, plan):
        return {s.rel: s.mode for s in plan.shares}

    def test_plain_dirs_share_read_only_and_rw_list_read_write(self):
        shares = self.shares(self.plan())
        self.assertEqual(shares["notes"], "ro")
        self.assertEqual(shares["Blitzy"], "rw")

    def test_denied_top_level_dir_is_not_shared(self):
        self.assertNotIn("Library", self.shares(self.plan()))

    def test_parent_of_denied_path_is_split_into_children(self):
        shares = self.shares(self.plan())
        self.assertNotIn(".config", shares)
        self.assertNotIn(".config/sops", shares)
        self.assertEqual(shares[".config/gh"], "ro")
        self.assertEqual(shares[".config/git"], "ro")

    def test_rw_descendant_splits_its_parent(self):
        shares = self.shares(self.plan(deny=("Library",)))
        self.assertNotIn(".config", shares)
        self.assertEqual(shares[".config/gcloud"], "rw")
        self.assertEqual(shares[".config/sops"], "ro")

    def test_rw_ancestor_makes_descendants_rw(self):
        self.assertEqual(self.shares(self.plan(rw=(".config",), deny=("Library",)))[".config"], "rw")

    def test_symlinks_become_links_and_plain_files_become_copies(self):
        plan = self.plan()
        links = dict((l.rel, l.target) for l in plan.links)
        self.assertEqual(links[".zshrc"], "/nix/store/abc-zshrc")
        self.assertEqual(links[".nix-profile"], "/nix/var/nix/profiles/per-user/sam/profile")
        self.assertNotIn(".nix-profile", self.shares(plan))
        self.assertIn(".zsh_history", plan.copies)
        # A file directly inside a split directory cannot be a share either.
        self.assertIn(".config/loose.toml", plan.copies)

    def test_denied_path_never_appears_anywhere(self):
        plan = self.plan()
        denied = ["Library", ".config/sops"]
        rels = [s.rel for s in plan.shares] + [l.rel for l in plan.links] + list(plan.copies)
        for rel in rels:
            for d in denied:
                self.assertFalse(rel == d or rel.startswith(d + "/"), rel)
        # No directory share may contain a denied path either.
        for share in plan.shares:
            for d in denied:
                self.assertFalse(d.startswith(share.rel + "/"), share.rel)

    def test_deny_wins_over_rw(self):
        shares = self.shares(self.plan(rw=(".config",), deny=(".config/sops",)))
        self.assertNotIn(".config", shares)
        self.assertNotIn(".config/sops", shares)
        self.assertEqual(shares[".config/gh"], "rw")

    def test_unreadable_directory_is_skipped_not_fatal(self):
        locked = self.home / ".config/locked"
        locked.mkdir()
        (locked / "inner").mkdir()
        os.chmod(locked, 0)
        try:
            # .config is split (sops is denied), so the planner must list .config/locked's
            # siblings without needing to read it; reading it fails and must not crash.
            shares = self.shares(self.plan(deny=("Library", ".config/sops", ".config/locked/inner")))
            self.assertNotIn(".config/locked", shares)
            self.assertIn(".config/gh", shares)
        finally:
            os.chmod(locked, 0o755)

    def test_tags_fit_the_virtio_fs_limit(self):
        deep = self.home / ("x" * 80)
        deep.mkdir()
        for share in self.plan().shares:
            self.assertLessEqual(len(share.tag.encode()), 36, share.tag)

    def test_sockets_are_skipped(self):
        sock = socket.socket(socket.AF_UNIX)
        path = self.home / "agent.sock"
        sock.bind(str(path))
        try:
            plan = self.plan()
            self.assertNotIn("agent.sock", plan.copies)
            self.assertNotIn("agent.sock", self.shares(plan))
        finally:
            sock.close()

    def test_missing_deny_entries_are_harmless(self):
        self.assertIn("notes", self.shares(self.plan(deny=("does/not/exist",))))

    def test_tags_are_unique_and_safe(self):
        tags = [s.tag for s in self.plan().shares]
        self.assertEqual(len(tags), len(set(tags)))
        for tag in tags:
            self.assertRegex(tag, r"^[A-Za-z0-9_-]+$")

    def test_paths_are_normalized(self):
        shares = self.shares(self.sp.plan(self.home, ["./Library/", ".config//sops"], ["Blitzy/"]))
        self.assertNotIn("Library", shares)
        self.assertNotIn(".config/sops", shares)
        self.assertEqual(shares["Blitzy"], "rw")


if __name__ == "__main__":
    unittest.main()
