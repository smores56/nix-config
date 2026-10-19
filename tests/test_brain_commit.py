import importlib.util
import json
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
        (self.vault / "CLAUDE.md").write_text("config\n\n## Link hosts\nexample.com\n")
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
        # A held index lock makes `git add` fail the way a concurrent git process would.
        (self.vault / ".git" / "index.lock").write_text("")
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

    def assert_signer_never_runs(self, *config):
        marker = Path(self.tmp.name) / "signer-ran"
        script = Path(self.tmp.name) / "signer.sh"
        script.write_text(f"#!/bin/sh\ntouch {marker}\n")
        script.chmod(0o755)
        for key, value in config:
            git(self.vault, "config", key, value.format(script=script))
        self.write("daily/d.md", "x\n")
        self.assertEqual(self.commit().status, "committed")
        self.assertFalse(marker.exists())

    def test_gpg_signing_program_never_runs(self):
        self.assert_signer_never_runs(("commit.gpgSign", "true"), ("gpg.program", "{script}"))

    def test_ssh_signing_program_never_runs(self):
        self.assert_signer_never_runs(
            ("commit.gpgSign", "true"),
            ("gpg.format", "ssh"),
            ("user.signingKey", "key::ssh-ed25519 AAAA"),
            ("gpg.ssh.program", "{script}"),
        )

    def test_x509_signing_program_never_runs(self):
        self.assert_signer_never_runs(
            ("commit.gpgSign", "true"), ("gpg.format", "x509"), ("gpg.x509.program", "{script}")
        )

    def test_instruction_files_are_refused_at_any_depth(self):
        # Assistants load these as trusted instructions from any directory they read.
        for name in ("wiki/CLAUDE.md", "daily/sub/AGENTS.md", "til/CLAUDE.local.md"):
            with self.subTest(name=name):
                self.assertFalse(self.bc.is_note_path(name))

    def set_link_hosts(self, *hosts):
        (self.vault / "CLAUDE.md").write_text("# cfg\n\n## Link hosts\n" + "\n".join(hosts) + "\n\n## Other\nx\n")
        git(self.vault, "commit", "-qam", "hosts")

    def test_links_to_configured_hosts_commit(self):
        self.set_link_hosts("example.com")
        self.write("daily/d.md", "- did a thing ([pr](https://example.com/o/r/pull/1)), dev at http://localhost:5173\n")
        self.assertEqual(self.commit().status, "committed")

    def test_links_to_other_hosts_are_refused(self):
        self.set_link_hosts("example.com")
        self.write("daily/d.md", "ok\nsee https://evil.example/p?d=secret-summary\n")
        result = self.commit()
        self.assertEqual(result.status, "refused")
        self.assertIn("daily/d.md:2", result.detail)
        self.assertIn("evil.example", result.detail)

    def test_lookalike_hosts_are_refused(self):
        self.set_link_hosts("example.com")
        for url in ("https://example.com.evil.test/x", "https://notexample.com/y", "https://example.com@evil.test/z"):
            with self.subTest(url=url):
                self.write("daily/d.md", url + "\n")
                self.assertEqual(self.commit().status, "refused")

    def test_images_and_raw_html_are_refused(self):
        self.set_link_hosts("example.com")
        for text in ("![x](https://example.com/a.png)", '<img src="https://example.com/a">', "<IFRAME src=x>"):
            with self.subTest(text=text):
                self.write("daily/d.md", text + "\n")
                self.assertEqual(self.commit().status, "refused")
                (self.vault / "daily/d.md").unlink()

    def test_engineering_prose_and_code_spans_are_fine(self):
        self.set_link_hosts("example.com")
        self.write(
            "daily/d.md",
            "- Fixed the OAuth redirect URL (FOO-1); dropped the @import of base.css\n"
            "- wrote `<div class=\"x\">` and `https://evil.test/in-code`\n"
            "```\n<img src=//evil.test/x> &amp; https://evil.test/fenced\n```\n",
        )
        self.assertEqual(self.commit().status, "committed")

    def test_reference_definitions_with_titles_are_checked(self):
        self.set_link_hosts("example.com")
        for line in ('[x]: obsidian://open "t"', "[x]: https://evil.test/a 'title'"):
            with self.subTest(line=line):
                self.write("daily/d.md", "see [x]\n\n" + line + "\n")
                self.assertEqual(self.commit().status, "refused")

    def test_trailing_punctuation_after_a_bare_host_is_fine(self):
        self.set_link_hosts("example.com")
        self.write("daily/d.md", "see https://example.com. and https://example.com, then https://example.com/a.\n")
        self.assertEqual(self.commit().status, "committed")

    def test_bulleted_host_lines_count_and_an_empty_section_is_missing(self):
        self.set_link_hosts("- example.com")
        self.write("daily/d.md", "https://example.com/a\n")
        self.assertEqual(self.commit().status, "committed")
        self.assertIsNone(self.bc.link_hosts("## Link hosts\n\n## Next\n"))

    def test_globally_ignored_non_note_files_do_not_block_commits(self):
        self.set_link_hosts("example.com")
        ignore = Path(self.tmp.name) / "global-ignore"
        ignore.write_text("**/.claude/settings.local.json\n")
        git(self.vault, "config", "core.excludesFile", str(ignore))
        (self.vault / ".claude").mkdir()
        (self.vault / ".claude" / "settings.local.json").write_text("{}")
        self.write("daily/d.md", "x\n")
        self.assertEqual(self.commit().status, "committed")
        self.assertNotIn(".claude", git(self.vault, "ls-files"))

    def test_a_naive_claim_time_does_not_crash(self):
        self.set_link_hosts("example.com")
        state = self.claim("abc", "2026-10-19T10:00:00")
        self.write("daily/d.md", "x\n")
        self.assertIn(self.bc.commit(self.vault, "x", env=ENV, state_dir=state).status, ("committed", "refused"))

    def test_angle_brackets_in_prose_are_fine(self):
        self.set_link_hosts("example.com")
        self.write("daily/d.md", "- passed <KEY> placeholders; a < b > c; latency < a second; see <source>; data: x; file:line cites\n")
        self.assertEqual(self.commit().status, "committed")

    def test_link_tricks_that_reach_other_hosts_are_refused(self):
        self.set_link_hosts("example.com")
        for target in (
            "https://evil.test\\@example.com/a",
            "https:evil.test/a",
            "https:\\\\evil.test/a",
            "//evil.test/a",
            "https://user:tok@example.com/a",
            "javascript:alert(1)",
            "data:text/html,x",
        ):
            with self.subTest(target=target):
                self.write("daily/d.md", f"[x]({target})\n")
                self.assertEqual(self.commit().status, "refused")

    def test_relative_and_wiki_links_are_fine(self):
        self.set_link_hosts("example.com")
        self.write("daily/d.md", "[[svc]] and [page](../wiki/svc.md) and [x](https://example.com/a?b=c#d)\n")
        self.assertEqual(self.commit().status, "committed")

    def test_styled_and_attributed_html_is_refused(self):
        self.set_link_hosts("example.com")
        for text in (
            '<span style="background:url(x)">', "<p class=x>", "&#x68;ttps", "<script>x</script>",
            "<img/src=//evil.test/x>", "<video/poster=//evil.test>", "<img\nsrc=//evil.test/x>",
            "[x](https&colon;//evil.test/a)", "<https://example.com/autolink>",
        ):
            with self.subTest(text=text):
                self.write("daily/d.md", text + "\n")
                self.assertEqual(self.commit().status, "refused")

    def test_a_missing_link_hosts_section_refuses(self):
        (self.vault / "CLAUDE.md").write_text("config\n")
        git(self.vault, "commit", "-qam", "no hosts")
        self.write("daily/d.md", "x\n")
        result = self.commit()
        self.assertEqual(result.status, "refused")
        self.assertIn("Link hosts", result.detail)

    def test_annotated_host_lines_count(self):
        self.set_link_hosts("example.com   (PRs)")
        self.write("daily/d.md", "https://example.com/a\n")
        self.assertEqual(self.commit().status, "committed")

    def claim(self, nonce, started):
        state = Path(self.tmp.name) / "state"
        state.mkdir(exist_ok=True)
        (state / "active.json").write_text(json.dumps({"nonce": nonce, "started": started}))
        return state

    def test_a_harvest_in_progress_blocks_other_commits(self):
        self.set_link_hosts("example.com")
        from datetime import datetime
        state = self.claim("abc", datetime.now().astimezone().isoformat())
        self.write("daily/d.md", "x\n")
        result = self.bc.commit(self.vault, "lint: x", env=ENV, state_dir=state)
        self.assertEqual(result.status, "refused")
        self.assertIn("in progress", result.detail)
        self.assertEqual(self.bc.commit(self.vault, "harvest: x", env=ENV, state_dir=state, run="abc").status, "committed")

    def test_a_stale_claim_does_not_block_commits(self):
        self.set_link_hosts("example.com")
        state = self.claim("abc", "2020-01-01T00:00:00+00:00")
        self.write("daily/d.md", "x\n")
        self.assertEqual(self.bc.commit(self.vault, "lint: x", env=ENV, state_dir=state).status, "committed")

    def test_globally_ignored_note_paths_are_still_seen(self):
        self.set_link_hosts("example.com")
        ignore = Path(self.tmp.name) / "global-ignore"
        ignore.write_text("*.md\n")
        git(self.vault, "config", "core.excludesFile", str(ignore))
        self.write("wiki/x.md", "x\n")
        self.assertEqual(self.commit().status, "committed")
        self.assertIn("wiki/x.md", git(self.vault, "ls-files"))


if __name__ == "__main__":
    unittest.main()
