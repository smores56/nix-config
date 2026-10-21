import contextlib
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).parents[1] / "modules/features/ai/memory/src"))

from memory_mcp import ingest_sources as sources  # noqa: E402
from memory_mcp.chunking import (  # noqa: E402
    MAX_SECTION_CHARS,
    context_line,
    document_title,
    sections_for,
)


class ChunkingTests(unittest.TestCase):
    def test_splits_on_top_level_h2_only(self):
        text = "# Title\n\nintro text\n\n## Design\n\n" + "design body " * 10 + "\n\n### Detail\n\nnested\n\n## Plan\n\n" + "plan body " * 10
        sections = sections_for(text)
        self.assertEqual([section.label for section in sections], ["Design", "Plan"])
        self.assertEqual([section.key for section in sections], ["design", "plan"])
        self.assertIn("### Detail", sections[0].body)

    def test_fenced_h2_is_not_a_heading(self):
        text = "## Design\n\n" + "body " * 20 + "\n\n```sh\n## not a heading\n```\n\n## Plan\n\n" + "plan " * 20
        sections = sections_for(text)
        self.assertEqual([section.label for section in sections], ["Design", "Plan"])
        self.assertIn("## not a heading", sections[0].body)

    def test_short_and_empty_sections_are_skipped(self):
        text = "## Empty\n\n## Tiny\n\nshort\n\n## Real\n\n" + "x" * 100
        sections = sections_for(text)
        self.assertEqual([section.label for section in sections], ["Real"])

    def test_document_without_h2_is_one_body_section(self):
        sections = sections_for("# Title\n\n" + "y" * 120)
        self.assertEqual(len(sections), 1)
        self.assertEqual(sections[0].key, "body")
        self.assertEqual(sections[0].label, "")

    def test_oversized_sections_split_on_line_boundaries(self):
        line = "z" * 100
        text = "## Big\n\n" + "\n".join([line] * (MAX_SECTION_CHARS // 50))
        sections = sections_for(text)
        self.assertGreater(len(sections), 1)
        self.assertEqual(sections[0].key, "big")
        self.assertTrue(all(len(section.body) <= 8000 for section in sections))
        self.assertEqual(len({section.key for section in sections}), len(sections))
        self.assertFalse(any(section.body.endswith("z" * 50) and not section.body.endswith("z" * 100) for section in sections))

    def test_duplicate_headings_get_unique_keys(self):
        text = "## Same\n\n" + "a" * 100 + "\n\n## Same\n\n" + "b" * 100
        self.assertEqual([section.key for section in sections_for(text)], ["same", "same-2"])

    def test_context_line_and_title(self):
        self.assertEqual(context_line("x", "T", "S"), "[x] T — S")
        self.assertEqual(context_line("x", "T"), "[x] T")
        self.assertEqual(document_title("# Hello\n\ntext", "fallback"), "Hello")
        self.assertEqual(document_title("text\n\n# Later", "fallback"), "fallback")


def issue(number, **kwargs):
    payload = {
        "number": number,
        "title": kwargs.get("title", f"Issue {number}"),
        "body": kwargs.get("body", ""),
        "labels": [{"name": name} for name in kwargs.get("labels", [])],
        "comments": kwargs.get("comments", []),
        "url": kwargs.get("url", f"https://github.com/smores56/sdlc/issues/{number}"),
    }
    return payload


class SdlcGroupTests(unittest.TestCase):
    def test_repo_label_maps_to_personal_group(self):
        self.assertEqual(sources.group_for_repo_label("nix-config"), "smores56--nix-config")

    def test_work_owner_is_refused(self):
        self.assertIsNone(sources.group_for_repo_label("blitzy-ai"))
        self.assertIsNone(sources.group_for_repo_label("blitzy--repo"))

    def test_task_inherits_the_nearest_feature_repo_label(self):
        issues = {
            100: issue(100, labels=["type:feature", "repo:kanbei"]),
            101: issue(101, body="Part of #100."),
            102: issue(102, body="Part of #101."),
        }
        self.assertEqual(sources.resolve_groups(102, issues)[0][0], "smores56--kanbei")
        self.assertEqual(sources.resolve_groups(101, issues)[0][0], "smores56--kanbei")

    def test_unlabeled_issue_falls_back_to_the_sdlc_group(self):
        issues = {1: issue(1, body="Just work.")}
        self.assertEqual(sources.resolve_groups(1, issues)[0][0], "smores56--sdlc")

    def test_cycle_and_missing_parent_fall_back(self):
        issues = {1: issue(1, body="Part of #2."), 2: issue(2, body="Part of #1.")}
        self.assertEqual(sources.resolve_groups(1, issues)[0][0], "smores56--sdlc")
        self.assertEqual(sources.resolve_groups(9, issues)[0][0], "smores56--sdlc")


class SdlcEpisodeTests(unittest.TestCase):
    def test_sections_and_comments_become_episodes_with_ids(self):
        issues = [
            issue(
                215,
                title="Memory",
                labels=["type:feature", "repo:nix-config"],
                body="# Memory\n\n## Design\n\n" + "d" * 120 + "\n\n## Plan\n\n" + "p" * 120,
                comments=[
                    {"author": {"login": "smores56"}, "body": "short", "url": "x", "id": "1"},
                    {
                        "author": {"login": "smores56"},
                        "body": "## Comment heading\n\n" + "c" * 120,
                        "url": "https://github.com/smores56/sdlc/issues/215#issuecomment-6296423868",
                        "createdAt": "2026-10-20T16:59:18Z",
                    },
                ],
            )
        ]
        plan = sources.sdlc_plan(issues)
        ids = [episode.source_id for episode in plan.episodes]
        self.assertEqual(
            ids,
            [
                "issue-215#design",
                "issue-215#plan",
                "issue-215#comment-6296423868#comment-heading",
            ],
        )
        first = plan.episodes[0]
        self.assertEqual(first.group, "smores56--nix-config")
        self.assertEqual(first.source, "sdlc")
        self.assertTrue(first.content.startswith("[smores56/sdlc#215] Memory — Design\n\n"))
        comment = plan.episodes[-1]
        self.assertIn("comment by smores56 on 2026-10-20", comment.content)
        self.assertIn("issuecomment-6296423868", comment.content)

    def test_work_labeled_issue_is_skipped_without_episodes(self):
        issues = [issue(1, title="Work", labels=["repo:blitzy-ai"], body="## Design\n\n" + "x" * 120)]
        plan = sources.sdlc_plan(issues)
        self.assertEqual(plan.episodes, [])
        self.assertEqual(plan.skipped[0].reason, "repo label 'blitzy-ai' belongs to the employer")

    def test_short_and_empty_bodies_still_become_one_episode(self):
        issues = [
            issue(5, title="Feature", labels=["repo:nix-config"], body=""),
            issue(6, title="Task", body="Part of #5."),
        ]
        plan = sources.sdlc_plan(issues)
        ids = [episode.source_id for episode in plan.episodes]
        self.assertEqual(ids, ["issue-5#body", "issue-6#body"])
        self.assertEqual(plan.episodes[0].content, "[smores56/sdlc#5] Feature")
        self.assertEqual(plan.episodes[1].content, "[smores56/sdlc#6] Task")
        self.assertEqual(plan.episodes[1].group, "smores56--nix-config")
        self.assertEqual(plan.skipped, [])

    def test_a_short_non_pointer_body_is_kept_under_the_title(self):
        issues = [issue(7, title="Task", labels=["repo:nix-config"], body="Fix the login button.")]
        plan = sources.sdlc_plan(issues)
        self.assertEqual(len(plan.episodes), 1)
        self.assertEqual(plan.episodes[0].content, "[smores56/sdlc#7] Task\n\nFix the login button.")

    def test_multiple_repo_labels_write_to_every_group(self):
        issues = [
            issue(8, title="Both", labels=["repo:nix-config", "repo:kanbei"], body="## Design\n\n" + "x" * 120)
        ]
        plan = sources.sdlc_plan(issues)
        groups = sorted(episode.group for episode in plan.episodes)
        self.assertEqual(groups, ["smores56--kanbei", "smores56--nix-config"])
        self.assertEqual(plan.skipped, [])

    def test_a_work_label_is_reported_without_dropping_the_personal_one(self):
        issues = [
            issue(9, title="Mixed", labels=["repo:blitzy-ai", "repo:nix-config"], body="## Design\n\n" + "x" * 120)
        ]
        plan = sources.sdlc_plan(issues)
        self.assertEqual([episode.group for episode in plan.episodes], ["smores56--nix-config"])
        self.assertEqual(plan.skipped[0].reason, "repo label 'blitzy-ai' belongs to the employer")

    def test_limit_caps_each_source(self):
        issues = [issue(1, labels=["repo:nix-config"], body="## A\n\n" + "a" * 120 + "\n\n## B\n\n" + "b" * 120)]
        plan = sources.sdlc_plan(issues).limited(1)
        self.assertEqual(len(plan.episodes), 1)
        self.assertEqual(plan.episodes[0].source_id, "issue-1#a")


class NotesTests(unittest.TestCase):
    def test_notes_are_global_sections(self):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "dragon-reading.md").write_text("# Dragons\n\n## Intro\n\n" + "d" * 120)
            Path(directory, "ignored.txt").write_text("nope")
            plan = sources.notes_plan(directory)
        self.assertEqual(len(plan.episodes), 1)
        episode = plan.episodes[0]
        self.assertEqual(episode.group, "global")
        self.assertEqual(episode.source_id, "note:dragon-reading.md#intro")
        self.assertTrue(episode.content.startswith("[note:dragon-reading.md] Dragons — Intro"))

    def test_missing_notes_dir_fails_clearly(self):
        with self.assertRaises(sources.SourceError):
            sources.notes_plan("/nonexistent/notes")

    def test_nested_notes_are_walked_recursively(self):
        with tempfile.TemporaryDirectory() as directory:
            nested = Path(directory, "reading", "2026")
            nested.mkdir(parents=True)
            Path(nested, "dragons.md").write_text("# Dragons\n\n## Intro\n\n" + "d" * 120)
            plan = sources.notes_plan(directory)
        self.assertEqual(plan.episodes[0].source_id, "note:reading/2026/dragons.md#intro")

    def test_oversize_notes_are_recorded_as_skips(self):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "big.md").write_text("x" * (sources.MAX_DOC_BYTES + 1))
            Path(directory, "ok.md").write_text("## Real\n\n" + "o" * 120)
            plan = sources.notes_plan(directory)
        skipped = {skip.source_id: skip.reason for skip in plan.skipped}
        self.assertIn("exceeds 200 KB", skipped["note:big.md#body"])
        self.assertEqual([episode.source_id for episode in plan.episodes], ["note:ok.md#real"])

    def test_a_note_symlink_outside_the_root_is_skipped(self):
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as outside:
            secret = Path(outside, "secret.md")
            secret.write_text("## Secret\n\n" + "s" * 120)
            Path(directory, "notes.md").symlink_to(secret)
            Path(directory, "real.md").write_text("## Real\n\n" + "r" * 120)
            plan = sources.notes_plan(directory)
        self.assertEqual([episode.source_id for episode in plan.episodes], ["note:real.md#real"])
        self.assertIn("outside the notes directory", plan.skipped[0].reason)

    def test_a_broken_note_symlink_is_an_unreadable_skip(self):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "gone.md").symlink_to(Path(directory, "missing.md"))
            Path(directory, "real.md").write_text("## Real\n\n" + "r" * 120)
            plan = sources.notes_plan(directory)
        self.assertEqual([episode.source_id for episode in plan.episodes], ["note:real.md#real"])
        self.assertIn("unreadable", plan.skipped[0].reason)


class RepoFilterTests(unittest.TestCase):
    def test_repo_and_repo_list_merge(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory, "repos.txt")
            path.write_text("# comment\nkanbei\n\nnix-config\n")
            self.assertEqual(
                sources.repo_filter(str(path), ["sdlc"]),
                {"kanbei", "nix-config", "sdlc"},
            )
        self.assertIsNone(sources.repo_filter(None, []))


class DocsTests(unittest.TestCase):
    def make_repo(self, root, name):
        repo = Path(root, name)
        (repo / ".git").mkdir(parents=True)
        return repo

    def make_git_repo(self, root, name, *, remotes=()):
        repo = Path(root, name)
        repo.mkdir(parents=True)
        subprocess.run(["git", "init", "-q", str(repo)], check=True, capture_output=True)
        for remote_name, url in remotes:
            subprocess.run(
                ["git", "-C", str(repo), "remote", "add", remote_name, url], check=True, capture_output=True
            )
        return repo

    def test_a_personal_fork_of_a_work_repo_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = self.make_git_repo(
                directory,
                "app",
                remotes=[
                    ("origin", "git@github.com:smores56/app.git"),
                    ("upstream", "git@github.com:blitzy-ai/app.git"),
                ],
            )
            (repo / "README.md").write_text("# App\n\n## Install\n\n" + "i" * 120)
            plan = sources.docs_plan(
                directory, repos=None, list_repos=lambda: [], read_readme=lambda _repo: None
            )
        self.assertEqual(plan.episodes, [])
        self.assertEqual(plan.skipped[0].source_id, "repo:app")
        self.assertIn("work repository", plan.skipped[0].reason)

    def test_a_symlinked_clone_is_refused(self):
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as outside:
            target = self.make_repo(outside, "real")
            (target / "README.md").write_text("# Real\n\n## Install\n\n" + "i" * 120)
            Path(directory, "linked").symlink_to(target, target_is_directory=True)
            plan = sources.docs_plan(
                directory, repos=None, list_repos=lambda: [], read_readme=lambda _repo: None
            )
        self.assertEqual(plan.episodes, [])
        self.assertIn("outside the docs root", plan.skipped[0].reason)

    def test_a_doc_symlink_outside_the_clone_is_skipped(self):
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as outside:
            secret = Path(outside, "secret.md")
            secret.write_text("# Secret\n\n## Hidden\n\n" + "s" * 120)
            repo = self.make_git_repo(directory, "nix-config")
            (repo / "README.md").symlink_to(secret)
            (repo / "docs").mkdir()
            (repo / "docs" / "linked.md").symlink_to(secret)
            plan = sources.docs_plan(
                directory, repos=None, list_repos=lambda: [], read_readme=lambda _repo: None
            )
        self.assertEqual(plan.episodes, [])

    def test_repo_filter_limits_both_local_and_remote(self):
        with tempfile.TemporaryDirectory() as directory:
            self.make_repo(directory, "nix-config")
            self.make_repo(directory, "sdlc")
            plan = sources.docs_plan(
                directory,
                repos={"sdlc"},
                list_repos=lambda: [],
                read_readme=lambda _repo: None,
            )
        self.assertEqual(plan.episodes, [])


class FetchIssuesTests(unittest.TestCase):
    def test_fetch_parses_json_and_rejects_non_lists(self):
        payload = json.dumps([{"number": 1}])
        self.assertEqual(sources.fetch_issues(lambda _args: payload)[0]["number"], 1)
        with self.assertRaises(sources.SourceError):
            sources.fetch_issues(lambda _args: "{}")

    def test_a_full_page_warns_about_truncation(self):
        payload = json.dumps([{"number": number} for number in range(sources.ISSUE_LIMIT)])
        with contextlib.redirect_stderr(io.StringIO()) as stderr:
            issues = sources.fetch_issues(lambda _args: payload)
        self.assertEqual(len(issues), sources.ISSUE_LIMIT)
        self.assertIn("may be truncated", stderr.getvalue())

    def test_a_full_repo_page_warns_about_truncation(self):
        payload = [{"name": f"repo-{index}"} for index in range(sources.REPO_LIMIT)]
        with mock.patch.object(sources, "gh_json", return_value=payload):
            with contextlib.redirect_stderr(io.StringIO()) as stderr:
                repos = sources.personal_repos()
        self.assertEqual(len(repos), sources.REPO_LIMIT)
        self.assertIn("may be truncated", stderr.getvalue())


class ReadmeErrorTests(unittest.TestCase):
    def test_a_404_means_no_readme(self):
        error = sources.SourceError("gh api failed: gh: Not Found (HTTP 404)")
        with mock.patch.object(sources, "gh_api", side_effect=error):
            self.assertIsNone(sources.repo_readme("empty"))

    def test_auth_and_network_errors_propagate(self):
        for message in (
            "gh api failed: HTTP 401: Bad credentials",
            "gh api failed: HTTP 403: rate limit exceeded",
            "dial tcp: no such host",
        ):
            with mock.patch.object(sources, "gh_api", side_effect=sources.SourceError(message)):
                with self.assertRaises(sources.SourceError):
                    sources.repo_readme("repo")

    def test_docs_plan_propagates_readme_errors(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(sources.SourceError):
                sources.docs_plan(
                    directory,
                    list_repos=lambda: [{"name": "kanbei", "isArchived": False, "isFork": False}],
                    read_readme=lambda _repo: (_ for _ in ()).throw(sources.SourceError("HTTP 401")),
                )


if __name__ == "__main__":
    unittest.main()
