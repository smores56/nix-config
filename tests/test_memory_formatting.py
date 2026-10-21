import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "modules/features/ai/memory/src"))

from memory_mcp.formatting import format_search, looks_path_like, path_query_note  # noqa: E402


class PathDetectionTests(unittest.TestCase):
    def test_slashes_and_filenames_are_path_like(self):
        for query in ("modules/nixos/memory.nix", "memory.nix", "src/main.py", "/etc/hosts"):
            with self.subTest(query=query):
                self.assertTrue(looks_path_like(query))

    def test_natural_language_is_not_path_like(self):
        for query in ("how does memory dedup work", "why did the deploy fail", "ticket 218"):
            with self.subTest(query=query):
                self.assertFalse(looks_path_like(query))

    def test_note_names_grep(self):
        note = path_query_note("src/main.py")
        self.assertIn("grep", note)
        self.assertIn("Nothing was invented", note)


class FormatSearchTests(unittest.TestCase):
    def test_no_results_shape(self):
        text = format_search(
            query="nothing",
            group="owner--repo",
            groups_searched=["owner--repo", "global"],
            nodes=[],
            facts=[],
            episodes=[],
        )
        self.assertIn("No memory results", text)
        self.assertIn("owner--repo, global", text)

    def test_nodes_and_facts_carry_group_and_time(self):
        text = format_search(
            query="memory",
            group="owner--repo",
            groups_searched=["owner--repo", "global"],
            nodes=[
                {
                    "uuid": "n1",
                    "name": "Graphiti",
                    "labels": ["Entity"],
                    "summary": "Memory extraction",
                    "group_id": "owner--repo",
                    "created_at": "2026-01-01T00:00:00Z",
                }
            ],
            facts=[
                {
                    "uuid": "e1",
                    "fact": "memory uses falkordb",
                    "group_id": "global",
                    "invalid_at": "2026-03-01T00:00:00Z",
                    "episodes": ["ep-1"],
                }
            ],
            episodes=[
                {
                    "uuid": "ep-1",
                    "name": "decision",
                    "created_at": "2026-01-02T00:00:00Z",
                    "source_description": "hash=abc; cwd=/x; source=maki",
                    "group_id": "global",
                }
            ],
        )
        self.assertIn("group=owner--repo", text)
        self.assertIn("2026-01-01T00:00:00Z", text)
        self.assertIn("invalidated=2026-03-01T00:00:00Z", text)
        self.assertIn("episodes: decision (2026-01-02T00:00:00Z)", text)
        self.assertIn("untrusted", text)

    def test_duplicates_are_collapsed(self):
        node = {"uuid": "n1", "name": "same", "group_id": "g"}
        text = format_search(
            query="q",
            group="g",
            groups_searched=["g"],
            nodes=[node, node],
            facts=[],
            episodes=[],
        )
        self.assertEqual(text.count("[1] node"), 1)
        self.assertNotIn("[2] node", text)

    def test_output_is_capped_at_the_limit(self):
        nodes = [
            {"uuid": f"n{index}", "name": f"n{index}", "summary": "x" * 400, "group_id": "g"}
            for index in range(10)
        ]
        text = format_search(
            query="q",
            group="g",
            groups_searched=["g"],
            nodes=nodes,
            facts=[],
            episodes=[],
            limit_chars=1000,
        )
        self.assertLessEqual(len(text), 1000 + 80)
        self.assertIn("truncated", text)


if __name__ == "__main__":
    unittest.main()
