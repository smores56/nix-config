import json
import sqlite3
import sys
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "modules/features/ai/memory/src"))

from memory_mcp.normalize import (  # noqa: E402
    content_hash,
    describe_source,
    episode_name,
    episode_uuid,
    normalize_content,
    normalize_tags,
)
from memory_mcp.registry import (  # noqa: E402
    Audit,
    Registry,
    RegistryEpisode,
    age_seconds,
    parse_timestamp,
)


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

    def test_uuid_matches_uuid5_of_group_and_hash(self):
        import uuid

        digest = content_hash("hello")
        expected = str(uuid.uuid5(uuid.NAMESPACE_URL, f"a--b:{digest}"))
        self.assertEqual(episode_uuid("a--b", digest), expected)

    def test_episode_name_comes_from_first_line(self):
        self.assertEqual(episode_name("First   line\nsecond", "abc"), "First line")
        self.assertEqual(episode_name("", "0123456789abcdef"), "memory 0123456789ab")

    def test_tags_are_sanitized_and_deduped(self):
        self.assertEqual(normalize_tags(["Foo Bar", "foo-bar", "!!", "x" * 40]), ["foo-bar", "x" * 24])

    def test_source_description_is_human_readable_only(self):
        self.assertEqual(
            describe_source("sdlc", "issue-215#design", "2026-10-03T00:00:00Z"),
            "sdlc issue-215#design (2026-10-03)",
        )
        self.assertNotIn("=", describe_source("notes", "note:a.md#body"))
        self.assertEqual(describe_source("agent", "", ""), "agent")


class RegistryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.registry = Registry(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def entry(self, group="owner--repo", digest="a" * 64, status="pending"):
        return RegistryEpisode(
            group=group,
            content_hash=digest,
            uuid=episode_uuid(group, digest),
            name="a memory",
            content="the content",
            kind="text",
            origin="agent",
            origin_ref="",
            actor="maki",
            cwd="/home/smores/code/example",
            tags=("one", "two"),
            valid_at="2026-01-01T00:00:00Z",
            created_at="2026-01-01T00:00:00Z",
            status=status,
        )

    def test_insert_and_lookup_keeps_typed_fields(self):
        entry = self.entry()
        self.assertTrue(self.registry.insert(entry))
        self.assertEqual(self.registry.lookup(entry.group, entry.content_hash), entry)

    def test_duplicate_insert_is_rejected(self):
        entry = self.entry()
        self.assertTrue(self.registry.insert(entry))
        self.assertFalse(self.registry.insert(entry))
        self.assertEqual(self.registry.stats(entry.group)["total"], 1)

    def test_tags_are_stored_as_json_array(self):
        entry = self.entry()
        self.registry.insert(entry)
        with sqlite3.connect(self.registry.db_path) as conn:
            raw = conn.execute("SELECT tags FROM episodes").fetchone()[0]
        self.assertEqual(json.loads(raw), ["one", "two"])
        self.assertEqual(self.registry.lookup(entry.group, entry.content_hash).tags, ("one", "two"))

    def test_queue_clears_prior_graph_identity_and_tombstone(self):
        entry = self.entry(status="tombstoned")
        self.registry.insert(replace(entry, graphiti_uuid="g-1", tombstone_reason="old"))
        queued = self.registry.queue(replace(entry, status="pending"))
        self.assertEqual(queued.status, "pending")
        self.assertEqual(queued.attempts, 0)
        self.assertIsNone(queued.graphiti_uuid)
        self.assertIsNone(queued.tombstone_reason)

    def test_mark_active_records_the_graph_uuid(self):
        entry = self.entry()
        self.registry.insert(entry)
        self.registry.mark_active(entry.group, entry.content_hash, "graph-123")
        stored = self.registry.lookup(entry.group, entry.content_hash)
        self.assertEqual(stored.status, "active")
        self.assertEqual(stored.graphiti_uuid, "graph-123")

    def test_mark_failed_records_the_reason(self):
        entry = self.entry()
        self.registry.insert(entry)
        self.registry.mark_failed(entry.group, entry.content_hash, "absent")
        stored = self.registry.lookup(entry.group, entry.content_hash)
        self.assertEqual(stored.status, "failed")
        self.assertEqual(stored.last_error, "absent")

    def test_record_attempt_counts_and_audits_in_one_transaction(self):
        entry = self.entry()
        self.registry.insert(entry)
        updated = self.registry.record_attempt(
            entry.group,
            entry.content_hash,
            error=None,
            audit=Audit(
                actor="maki",
                group=entry.group,
                tool="memory_write",
                status="queued",
                content_hash=entry.content_hash,
                uuid=entry.uuid,
            ),
        )
        self.assertEqual(updated.attempts, 1)
        with sqlite3.connect(self.registry.db_path) as conn:
            rows = conn.execute("SELECT tool, status FROM audit").fetchall()
        self.assertEqual(rows, [("memory_write", "queued")])

    def test_find_exact_uuid_hash_prefix_and_origin_ref(self):
        entry = self.entry()
        self.registry.insert(entry)
        self.assertEqual(self.registry.find_exact(entry.group, entry.uuid), entry)
        self.assertEqual(self.registry.find_exact(entry.group, entry.content_hash), entry)
        self.assertEqual(self.registry.find_exact(entry.group, entry.content_hash[:12]), entry)
        self.assertIsNone(self.registry.find_exact("other--repo", entry.uuid))

    def test_find_exact_origin_ref(self):
        entry = replace(self.entry(), origin="sdlc", origin_ref="issue-215#design")
        self.registry.insert(entry)
        self.assertEqual(
            self.registry.find_exact(entry.group, "sdlc:issue-215#design"), entry
        )
        self.assertIsNone(self.registry.find_exact(entry.group, "sdlc:issue-215#plan"))

    def test_find_exact_does_not_match_names_or_short_prefixes(self):
        entry = self.entry()
        self.registry.insert(entry)
        self.assertIsNone(self.registry.find_exact(entry.group, "a memory"))
        self.assertIsNone(self.registry.find_exact(entry.group, entry.content_hash[:11]))
        self.assertIsNone(self.registry.find_exact(entry.group, "%" * 12))

    def test_find_exact_rejects_an_ambiguous_hash_prefix(self):
        first = replace(self.entry(digest="a" * 64), uuid="uuid-1")
        second = replace(self.entry(digest="a" * 63 + "b"), uuid="uuid-2")
        self.registry.insert(first)
        self.registry.insert(second)
        self.assertIsNone(self.registry.find_exact(first.group, "a" * 12))

    def test_tombstone_marks_status_without_deleting(self):
        entry = self.entry(status="active")
        self.registry.insert(entry)
        updated = self.registry.tombstone(entry, reason="superseded")
        self.assertEqual(updated.status, "tombstoned")
        self.assertIsNotNone(updated.tombstoned_at)
        self.assertEqual(self.registry.lookup(entry.group, entry.content_hash).status, "tombstoned")
        stats = self.registry.stats(entry.group)
        self.assertEqual(stats["tombstoned"], 1)
        self.assertEqual(stats["active"], 0)

    def test_pending_lists_only_pending_rows_oldest_first(self):
        newer = replace(self.entry(digest="b" * 64), created_at="2026-01-02T00:00:00Z")
        older = replace(self.entry(digest="c" * 64), created_at="2026-01-01T00:00:00Z")
        self.registry.insert(newer)
        self.registry.insert(older)
        self.registry.insert(self.entry(digest="d" * 64, status="active"))
        pending = self.registry.pending()
        self.assertEqual([item.content_hash for item in pending], ["c" * 64, "b" * 64])

    def test_by_graphiti_uuids_joins_rows(self):
        first = replace(self.entry(digest="b" * 64), graphiti_uuid="g-1")
        second = replace(self.entry(digest="c" * 64), graphiti_uuid="g-2")
        self.registry.insert(first)
        self.registry.insert(second)
        found = self.registry.by_graphiti_uuids({"g-1", "g-2", "missing"})
        self.assertEqual(set(found), {"g-1", "g-2"})
        self.assertEqual(found["g-1"].content_hash, "b" * 64)

    def test_promotion_bookkeeping(self):
        entry = self.entry()
        self.registry.insert(entry)
        self.assertFalse(self.registry.is_promoted(entry.uuid, "global"))
        self.registry.record_promotion(
            source_uuid=entry.uuid,
            target_uuid=episode_uuid("global", entry.content_hash),
            source_group=entry.group,
            target_group="global",
            actor="cli",
        )
        self.assertTrue(self.registry.is_promoted(entry.uuid, "global"))
        self.assertTrue(self.registry.is_promoted(entry.uuid, "global"))

    def test_stats_count_every_status(self):
        self.registry.insert(self.entry(digest="a" * 64, status="active"))
        self.registry.insert(self.entry(digest="b" * 64, status="pending"))
        self.registry.insert(self.entry(digest="c" * 64, status="failed"))
        self.registry.insert(self.entry(digest="d" * 64, status="tombstoned"))
        stats = self.registry.stats("owner--repo")
        self.assertEqual((stats["total"], stats["active"], stats["pending"], stats["failed"]), (4, 1, 1, 1))
        self.assertEqual(stats["tombstoned"], 1)

    def test_audit_table_replaces_the_jsonl_log(self):
        self.registry.audit(
            Audit(
                actor="cli",
                group="g",
                tool="memory_write",
                status="queued",
                content_hash="x",
                details={"note": "one"},
            )
        )
        self.registry.audit(Audit(actor="maki", group="g", tool="memory_search", status="ok"))
        with sqlite3.connect(self.registry.db_path) as conn:
            rows = conn.execute(
                "SELECT actor, tool, status, details FROM audit ORDER BY id"
            ).fetchall()
        self.assertEqual([(row[0], row[1], row[2]) for row in rows], [
            ("cli", "memory_write", "queued"),
            ("maki", "memory_search", "ok"),
        ])
        self.assertEqual(json.loads(rows[0][3]), {"note": "one"})
        self.assertFalse((Path(self.tmp.name) / "audit.jsonl").exists())

    def test_timestamp_helpers(self):
        self.assertIsNotNone(parse_timestamp("2026-01-01T00:00:00Z"))
        self.assertIsNone(parse_timestamp("not-a-timestamp"))
        self.assertEqual(age_seconds("2026-01-01T00:00:00Z", parse_timestamp("2026-01-01T01:00:00Z")), 3600)
        self.assertIsNone(age_seconds("bad", parse_timestamp("2026-01-01T00:00:00Z")))


if __name__ == "__main__":
    unittest.main()
