import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "modules/features/ai/memory/src"))

from memory_mcp.normalize import (  # noqa: E402
    content_hash,
    episode_name,
    episode_uuid,
    normalize_content,
    normalize_tags,
)
from memory_mcp.store import Entry, Store  # noqa: E402


class NormalizeTests(unittest.TestCase):
    def test_line_endings_and_trailing_space_normalize(self):
        self.assertEqual(normalize_content("  a  \r\nb\t\r\n\r\n\r\nc  \n"), "a\nb\n\nc")

    def test_inline_space_runs_collapse(self):
        self.assertEqual(normalize_content("a \t  b"), "a b")

    def test_hash_is_stable_across_formatting(self):
        self.assertEqual(
            content_hash(normalize_content("one\r\n\r\ntwo\n")),
            content_hash(normalize_content("one\n\ntwo")),
        )

    def test_empty_content_is_rejected(self):
        for value in ("", " \n\t\n "):
            with self.subTest(value=value), self.assertRaises(ValueError):
                normalize_content(value)

    def test_uuid_is_deterministic_and_group_scoped(self):
        digest = content_hash("hello")
        self.assertEqual(episode_uuid("a--b", digest), episode_uuid("a--b", digest))
        self.assertNotEqual(episode_uuid("a--b", digest), episode_uuid("c--d", digest))

    def test_episode_name_comes_from_first_line(self):
        self.assertEqual(episode_name("First   line\nsecond", "abc"), "First line")
        self.assertEqual(episode_name("", "0123456789abcdef"), "memory 0123456789ab")

    def test_tags_are_sanitized_and_deduped(self):
        self.assertEqual(normalize_tags(["Foo Bar", "foo-bar", "!!", "x" * 40]), ["foo-bar", "x" * 24])


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = Store(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def entry(self, group="owner--repo", digest="a" * 64, status="active"):
        return Entry(
            group=group,
            content_hash=digest,
            uuid=episode_uuid(group, digest),
            name="a memory",
            content="the content",
            source="maki",
            cwd="/home/smores/code/example",
            created_at="2026-01-01T00:00:00Z",
            tags="one,two",
            status=status,
        )

    def test_insert_and_lookup(self):
        entry = self.entry()
        self.assertTrue(self.store.insert(entry))
        self.assertEqual(self.store.lookup(entry.group, entry.content_hash), entry)

    def test_duplicate_insert_is_rejected(self):
        entry = self.entry()
        self.assertTrue(self.store.insert(entry))
        self.assertFalse(self.store.insert(entry))
        self.assertEqual(self.store.stats(entry.group)["total"], 1)

    def test_find_by_uuid_hash_prefix_and_name(self):
        entry = self.entry()
        self.store.insert(entry)
        self.assertEqual(self.store.find(entry.group, entry.uuid), entry)
        self.assertEqual(self.store.find(entry.group, entry.content_hash), entry)
        self.assertEqual(self.store.find(entry.group, entry.content_hash[:12]), entry)
        self.assertEqual(self.store.find(entry.group, "a memory"), entry)
        self.assertIsNone(self.store.find("other--repo", entry.uuid))

    def test_tombstone_marks_status_without_deleting(self):
        entry = self.entry()
        self.store.insert(entry)
        updated = self.store.tombstone(entry, actor="cli", reason="superseded")
        self.assertEqual(updated.status, "tombstoned")
        self.assertIsNotNone(updated.tombstoned_at)
        self.assertEqual(self.store.lookup(entry.group, entry.content_hash).status, "tombstoned")
        self.assertEqual(self.store.stats(entry.group)["tombstoned"], 1)
        self.assertEqual(self.store.stats(entry.group)["active"], 0)

    def test_promotion_bookkeeping(self):
        entry = self.entry()
        self.store.insert(entry)
        self.assertFalse(self.store.is_promoted(entry.uuid, "global"))
        self.store.record_promotion(
            source_uuid=entry.uuid,
            target_uuid=episode_uuid("global", entry.content_hash),
            source_group=entry.group,
            target_group="global",
            actor="cli",
        )
        self.assertTrue(self.store.is_promoted(entry.uuid, "global"))

    def test_audit_appends_jsonl(self):
        self.store.audit(actor="cli", group="g", tool="memory_write", status="stored", content_hash="x")
        self.store.audit(actor="maki", group="g", tool="memory_search", status="ok")
        lines = [json.loads(line) for line in self.store.audit_path.read_text().splitlines()]
        self.assertEqual([line["tool"] for line in lines], ["memory_write", "memory_search"])
        self.assertEqual(lines[0]["actor"], "cli")
        self.assertEqual(lines[0]["status"], "stored")


if __name__ == "__main__":
    unittest.main()
