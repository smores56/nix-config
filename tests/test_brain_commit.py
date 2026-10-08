import importlib.util
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


def load_module():
    path = Path(__file__).parents[1] / "modules/features/ai/brain/brain-commit.py"
    spec = importlib.util.spec_from_file_location("brain_commit", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ENV = {
    **os.environ,
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_AUTHOR_NAME": "t",
    "GIT_AUTHOR_EMAIL": "t@t",
    "GIT_COMMITTER_NAME": "t",
    "GIT_COMMITTER_EMAIL": "t@t",
}


def git(repo, *args):
    return subprocess.run(
        ["git", "-C", str(repo), *args], env=ENV, check=True, capture_output=True, text=True
    ).stdout


class BrainCommitTests(unittest.TestCase):
    def setUp(self):
        self.bc = load_module()
        self.tmp = tempfile.TemporaryDirectory()
        self.vault = Path(self.tmp.name) / "brain"
        self.vault.mkdir()
        git(self.vault, "init", "-q")
        (self.vault / "CLAUDE.md").write_text("config\n")
        git(self.vault, "add", "CLAUDE.md")
        git(self.vault, "commit", "-qm", "init")

    def tearDown(self):
        self.tmp.cleanup()

    def commit(self, message="harvest: day"):
        return self.bc.commit(self.vault, message, env=ENV)

    def head_count(self):
        return int(git(self.vault, "rev-list", "--count", "HEAD"))

    def write(self, rel, text):
        path = self.vault / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def test_commits_allowlisted_notes_with_the_message(self):
        self.write("daily/2026-10-07.md", "# day\n")
        self.write("index.md", "- [[x]]\n")
        result = self.commit("harvest: 2026-10-07")
        self.assertEqual(result.status, "committed")
        self.assertEqual(git(self.vault, "log", "-1", "--format=%s").strip(), "harvest: 2026-10-07")
        self.assertEqual(git(self.vault, "status", "--porcelain"), "")

    def test_nothing_to_commit_is_a_quiet_success(self):
        result = self.commit()
        self.assertEqual(result.status, "nothing")
        self.assertEqual(self.head_count(), 1)

    def test_refuses_a_vault_with_a_remote(self):
        git(self.vault, "remote", "add", "origin", "https://example.invalid/x.git")
        self.write("daily/d.md", "x\n")
        self.assertEqual(self.commit().status, "refused")
        self.assertEqual(self.head_count(), 1)

    def test_refuses_a_directory_inside_another_repo(self):
        nested = self.vault / "wiki"
        nested.mkdir()
        (nested / "a.md").write_text("x\n")
        result = self.bc.commit(nested, "harvest: x", env=ENV)
        self.assertEqual(result.status, "refused")
        self.assertEqual(self.head_count(), 1)

    def test_refuses_changes_outside_the_note_paths_and_stages_nothing(self):
        self.write("daily/d.md", "x\n")
        self.write("CLAUDE.md", "tampered\n")
        result = self.commit()
        self.assertEqual(result.status, "refused")
        self.assertIn("CLAUDE.md", result.detail)
        self.assertEqual(git(self.vault, "diff", "--cached", "--name-only"), "")

    def test_refuses_secrets_and_leaves_the_index_clean(self):
        self.write("daily/d.md", "token ghp_" + "a" * 36 + "\n")
        result = self.commit()
        self.assertEqual(result.status, "refused")
        self.assertIn("daily/d.md", result.detail)
        self.assertNotIn("ghp_", result.detail)
        self.assertEqual(git(self.vault, "diff", "--cached", "--name-only"), "")
        self.assertEqual(self.head_count(), 1)

    def test_secrets_in_non_ascii_filenames_are_caught(self):
        self.write("wiki/josé.md", "token ghp_" + "a" * 36 + "\n")
        result = self.commit()
        self.assertEqual(result.status, "refused")
        self.assertIn("josé.md:1", result.detail)
        self.assertEqual(self.head_count(), 1)

    def test_diff_config_cannot_hide_secrets(self):
        git(self.vault, "config", "diff.noprefix", "true")
        git(self.vault, "config", "diff.external", "true")
        self.write("daily/d.md", "token ghp_" + "a" * 36 + "\n")
        self.assertEqual(self.commit().status, "refused")
        self.assertEqual(self.head_count(), 1)

    def test_only_markdown_notes_are_allowed_under_note_dirs(self):
        for rel in ("wiki/.gitattributes", "daily/script.sh"):
            with self.subTest(rel=rel):
                self.write(rel, "* -diff\n")
                result = self.commit()
                self.assertEqual(result.status, "refused")
                self.assertIn(rel, result.detail)
                (self.vault / rel).unlink()

    def test_symlinked_notes_are_refused(self):
        outside = Path(self.tmp.name) / "outside.txt"
        outside.write_text("x\n")
        (self.vault / "daily").mkdir()
        (self.vault / "daily" / "x.md").symlink_to(outside)
        result = self.commit()
        self.assertEqual(result.status, "refused")
        self.assertIn("daily/x.md", result.detail)

    def test_refuses_repos_with_filter_drivers(self):
        marker = Path(self.tmp.name) / "filter-ran"
        git(self.vault, "config", "filter.x.clean", f"sh -c 'touch {marker}; cat'")
        self.write("daily/d.md", "x\n")
        self.assertEqual(self.commit().status, "refused")
        self.assertFalse(marker.exists())

    def test_fsmonitor_never_runs(self):
        marker = Path(self.tmp.name) / "fsmonitor-ran"
        script = Path(self.tmp.name) / "fsmon.sh"
        script.write_text(f"#!/bin/sh\ntouch {marker}\n")
        script.chmod(0o755)
        git(self.vault, "config", "core.fsmonitor", str(script))
        self.write("daily/d.md", "x\n")
        self.assertEqual(self.commit().status, "committed")
        self.assertFalse(marker.exists())

    def test_inherited_git_dir_is_ignored(self):
        other = Path(self.tmp.name) / "other"
        other.mkdir()
        git(other, "init", "-q")
        env = {**ENV, "GIT_DIR": str(other / ".git"), "GIT_WORK_TREE": str(self.vault)}
        self.write("daily/d.md", "x\n")
        result = self.bc.commit(self.vault, "harvest: x", env=env)
        self.assertEqual(result.status, "committed")
        self.assertEqual(self.head_count(), 2)

    def test_pre_staged_renames_commit_cleanly(self):
        self.write("wiki/a.md", "x\n")
        self.commit()
        git(self.vault, "mv", "wiki/a.md", "wiki/b.md")
        self.assertEqual(self.commit("lint: merge").status, "committed")
        self.assertEqual(git(self.vault, "ls-files", "wiki").split(), ["wiki/b.md"])

    def test_git_failures_are_refusals_not_crashes(self):
        git(self.vault, "config", "commit.gpgSign", "true")
        git(self.vault, "config", "gpg.program", "false")
        self.write("daily/d.md", "x\n")
        result = self.commit()
        self.assertEqual(result.status, "refused")
        self.assertEqual(git(self.vault, "diff", "--cached", "--name-only"), "")

    def test_git_hooks_never_run(self):
        hook = self.vault / ".git" / "hooks" / "pre-commit"
        marker = Path(self.tmp.name) / "hook-ran"
        hook.write_text(f"#!/bin/sh\ntouch {marker}\n")
        hook.chmod(0o755)
        self.write("daily/d.md", "x\n")
        self.assertEqual(self.commit().status, "committed")
        self.assertFalse(marker.exists())


if __name__ == "__main__":
    unittest.main()
