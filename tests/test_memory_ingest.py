import json
import sys
import tempfile
import unittest
from pathlib import Path

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
        self.assertEqual(sources.resolve_group(102, issues)[0], "smores56--kanbei")
        self.assertEqual(sources.resolve_group(101, issues)[0], "smores56--kanbei")

    def test_unlabeled_issue_falls_back_to_the_sdlc_group(self):
        issues = {1: issue(1, body="Just work.")}
        self.assertEqual(sources.resolve_group(1, issues)[0], "smores56--sdlc")

    def test_cycle_and_missing_parent_fall_back(self):
        issues = {1: issue(1, body="Part of #2."), 2: issue(2, body="Part of #1.")}
        self.assertEqual(sources.resolve_group(1, issues)[0], "smores56--sdlc")
        self.assertEqual(sources.resolve_group(9, issues)[0], "smores56--sdlc")


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

    def test_task_with_only_a_part_of_body_builds_nothing(self):
        issues = [
            issue(5, title="Feature", labels=["repo:nix-config"], body=""),
            issue(6, title="Task", body="Part of #5."),
        ]
        plan = sources.sdlc_plan(issues)
        self.assertEqual(plan.episodes, [])
        self.assertEqual(len(plan.skipped), 2)

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

    def test_local_docs_are_sectioned_and_filtered(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = self.make_repo(directory, "nix-config")
            (repo / "README.md").write_text("# nix-config\n\n## Install\n\n" + "i" * 120)
            (repo / "AGENTS.md").write_text("# Guide\n\n" + "g" * 120)
            (repo / "docs").mkdir()
            (repo / "docs" / "note.md").write_text("## Note\n\n" + "n" * 120)
            (repo / "docs" / "big.md").write_text("x" * (sources.MAX_DOC_BYTES + 1))
            (repo / ".worktrees").mkdir()
            (repo / ".worktrees" / "skip.md").write_text("## Skip\n\n" + "s" * 120)
            plan = sources.docs_plan(
                directory,
                repos={"nix-config"},
                list_repos=lambda: [],
                read_readme=lambda _repo: None,
            )
        ids = {episode.source_id for episode in plan.episodes}
        self.assertIn("repo:nix-config:README.md#install", ids)
        self.assertIn("repo:nix-config:AGENTS.md#body", ids)
        self.assertIn("repo:nix-config:docs/note.md#note", ids)
        self.assertFalse(any("skip.md" in source_id for source_id in ids))
        self.assertFalse(any("big.md" in source_id for source_id in ids))
        self.assertTrue(all(episode.group == "smores56--nix-config" for episode in plan.episodes))

    def test_remote_readmes_fill_in_uncloned_and_skip_archived_forks(self):
        calls = []

        def readme(repo):
            calls.append(repo)
            return "# " + repo + "\n\n" + "r" * 120 if repo else None

        with tempfile.TemporaryDirectory() as directory:
            self.make_repo(directory, "sdlc")
            plan = sources.docs_plan(
                directory,
                repos=None,
                list_repos=lambda: [
                    {"name": "kanbei", "isArchived": False, "isFork": False},
                    {"name": "old", "isArchived": True, "isFork": False},
                    {"name": "fork", "isArchived": False, "isFork": True},
                    {"name": "sdlc", "isArchived": False, "isFork": False},
                ],
                read_readme=readme,
            )
        self.assertEqual(calls, ["kanbei"])
        ids = {episode.source_id for episode in plan.episodes}
        self.assertIn("repo:kanbei:README.md#body", ids)
        self.assertFalse(any(source_id.startswith("repo:old") for source_id in ids))
        self.assertFalse(any(source_id.startswith("repo:fork") for source_id in ids))

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


if __name__ == "__main__":
    unittest.main()
