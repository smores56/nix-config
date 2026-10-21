import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "modules/features/ai/memory/src"))

from memory_mcp.groups import (  # noqa: E402
    GroupRefused,
    WorkRefused,
    derive_group,
    parse_remote,
    sanitize_slug,
    validate_group,
)


class GitFixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.env = {
            "PATH": os.environ["PATH"],
            "HOME": str(self.home),
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_SYSTEM": os.devnull,
            "GIT_AUTHOR_NAME": "Test",
            "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test",
            "GIT_COMMITTER_EMAIL": "test@example.com",
        }

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, cwd, *args):
        return subprocess.run(
            ["git", "-C", str(cwd), *args],
            capture_output=True,
            text=True,
            env=self.env,
            check=True,
        )

    def repo(self, name="repo"):
        path = self.root / name
        path.mkdir()
        self.git(path, "init", "-q", "-b", "main")
        return path


class GroupDerivationTests(GitFixture):
    def test_ssh_remote_becomes_owner_repo(self):
        repo = self.repo()
        self.git(repo, "remote", "add", "origin", "git@github.com:smores56/nix-config.git")
        context = derive_group(repo, self.env)
        self.assertEqual(context.group, "smores56--nix-config")
        self.assertEqual(context.cwd, os.path.abspath(repo))
        self.assertEqual(context.repo_root, os.path.abspath(repo))

    def test_https_remote_strips_git_suffix(self):
        repo = self.repo()
        self.git(repo, "remote", "add", "origin", "https://github.com/owner/repo.git")
        self.assertEqual(derive_group(repo, self.env).group, "owner--repo")

    def test_ssh_url_remote(self):
        repo = self.repo()
        self.git(repo, "remote", "add", "origin", "ssh://git@github.com/owner/repo")
        self.assertEqual(derive_group(repo, self.env).group, "owner--repo")

    def test_origin_wins_over_upstream(self):
        repo = self.repo()
        self.git(repo, "remote", "add", "upstream", "git@github.com:someone/other.git")
        self.git(repo, "remote", "add", "origin", "git@github.com:owner/repo.git")
        self.assertEqual(derive_group(repo, self.env).group, "owner--repo")

    def test_upstream_used_when_no_origin(self):
        repo = self.repo()
        self.git(repo, "remote", "add", "upstream", "git@github.com:owner/repo.git")
        self.assertEqual(derive_group(repo, self.env).group, "owner--repo")

    def test_repo_without_remote_is_local(self):
        repo = self.repo("My Repo!")
        self.assertEqual(derive_group(repo, self.env).group, "local--My-Repo")

    def test_non_repo_uses_basename(self):
        path = self.root / "scratch pad"
        path.mkdir()
        self.assertEqual(derive_group(path, self.env).group, "local--scratch-pad")

    def test_worktree_resolves_parent_repo(self):
        repo = self.repo()
        self.git(repo, "remote", "add", "origin", "git@github.com:owner/repo.git")
        self.git(repo, "commit", "-q", "--allow-empty", "-m", "init")
        worktree = repo / ".worktrees" / "feature"
        self.git(repo, "worktree", "add", "-q", str(worktree), "-b", "feature")
        context = derive_group(worktree, self.env)
        self.assertEqual(context.group, "owner--repo")
        self.assertEqual(context.repo_root, os.path.abspath(repo))


class WorkRefusalTests(GitFixture):
    def assert_work(self, repo):
        with self.assertRaises(WorkRefused):
            derive_group(repo, self.env)

    def test_smores_flow_pr_refuses(self):
        repo = self.repo()
        self.git(repo, "remote", "add", "origin", "git@github.com:smores56/nix-config.git")
        self.git(repo, "config", "smores.flow", "pr")
        self.assert_work(repo)

    def test_work_email_refuses(self):
        repo = self.repo()
        self.git(repo, "remote", "add", "origin", "git@github.com:smores56/nix-config.git")
        self.git(repo, "config", "user.email", "smohr@blitzy.com")
        self.assert_work(repo)

    def test_work_ssh_command_refuses(self):
        repo = self.repo()
        self.git(repo, "remote", "add", "origin", "git@github.com:smores56/nix-config.git")
        self.git(repo, "config", "core.sshCommand", "ssh -F ~/.ssh/config.work")
        self.assert_work(repo)

    def test_work_upstream_refuses_even_with_personal_origin(self):
        repo = self.repo()
        self.git(repo, "remote", "add", "origin", "git@github.com:smores56/fork.git")
        self.git(repo, "remote", "add", "upstream", "git@github.com:blitzy-something/service.git")
        self.assert_work(repo)

    def test_work_remote_on_https(self):
        repo = self.repo()
        self.git(repo, "remote", "add", "origin", "https://github.com/BLITZY-org/repo.git")
        self.assert_work(repo)


class GroupValidationTests(unittest.TestCase):
    def test_global_is_allowed(self):
        self.assertEqual(validate_group("global"), "global")

    def test_owner_repo_is_allowed(self):
        self.assertEqual(validate_group("smores56--nix-config"), "smores56--nix-config")

    def test_work_names_are_refused(self):
        for group in ("work", "work:foo", "work--repo", "blitzy-org--repo", "BLITZY--x"):
            with self.subTest(group=group), self.assertRaises(GroupRefused):
                validate_group(group)

    def test_malformed_groups_are_refused(self):
        for group in ("", "../escape", "owner/repo", "has space", "x" * 129):
            with self.subTest(group=group), self.assertRaises(GroupRefused):
                validate_group(group)

    def test_sanitize_slug(self):
        self.assertEqual(sanitize_slug("My Repo.git"), "My-Repo-git")
        self.assertEqual(sanitize_slug("---"), "unknown")
        self.assertEqual(len(sanitize_slug("x" * 200)), 60)

    def test_parse_remote_rejects_unparseable(self):
        self.assertIsNone(parse_remote("origin", "file:///tmp/repo"))
        self.assertIsNone(parse_remote("origin", "not-a-remote"))
        self.assertIsNone(parse_remote("origin", "https://github.com/onlyowner"))


if __name__ == "__main__":
    unittest.main()
