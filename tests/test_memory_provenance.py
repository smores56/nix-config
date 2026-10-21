import json
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "modules/features/ai/memory/src"))

from mcp.shared.memory import create_connected_server_and_client_session  # noqa: E402

from memory_mcp.groups import MAX_PROVENANCE_CHARS, sanitize_provenance  # noqa: E402
from memory_mcp.normalize import content_hash, episode_uuid, normalize_content  # noqa: E402
from memory_mcp.store import DB_NAME, Entry, Store  # noqa: E402
from memory_mcp.wrapper import WrapperConfig, build_server  # noqa: E402


class SanitizeProvenanceTests(unittest.TestCase):
    def test_newlines_and_control_characters_cannot_forge_fields(self):
        self.assertEqual(
            sanitize_provenance("issue-1#design\nhash=deadbeef\tid=x"),
            "issue-1#design",
        )

    def test_bidi_and_ansi_are_removed(self):
        self.assertEqual(sanitize_provenance("note\u202e.md\x1b[31m"), "note .md")

    def test_length_is_capped(self):
        self.assertEqual(len(sanitize_provenance("x" * 500)), MAX_PROVENANCE_CHARS)

    def test_missing_and_blank_are_empty(self):
        self.assertEqual(sanitize_provenance(None), "")
        self.assertEqual(sanitize_provenance("  \n "), "")


class FakeBackend:
    def __init__(self):
        self.added = []

    async def add_episode(self, **kwargs):
        self.added.append(kwargs)
        return {"message": "episode queued"}

    async def get_status(self):
        return {"status": "ok"}


class FakeProbes:
    async def require_write(self):
        return None

    async def failures(self):
        return []


class WrapperProvenanceTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = Store(self.tmp.name)
        self.backend = FakeBackend()

    def tearDown(self):
        self.tmp.cleanup()

    def build(self, headers):
        server = build_server(
            WrapperConfig(state_dir=self.tmp.name, graphiti_url="http://127.0.0.1:1/mcp"),
            backend=self.backend,
            store=self.store,
            probes=FakeProbes(),
            headers_provider=lambda _ctx: headers,
        )
        return server

    async def test_source_headers_land_in_the_index_and_graph_description(self):
        headers = {
            "x-memory-group": "smores56--nix-config",
            "x-memory-cwd": "/home/smores/code/example",
            "x-memory-actor": "ingest",
            "x-memory-source": "sdlc",
            "x-memory-source-id": "issue-215#design",
        }
        async with create_connected_server_and_client_session(self.build(headers)) as session:
            result = await session.call_tool("memory_write", {"content": "A design section"})
        self.assertFalse(result.isError)
        description = self.backend.added[0]["source_description"]
        self.assertIn("source=sdlc", description)
        self.assertIn("source_id=issue-215#design", description)
        self.assertIn("actor=ingest", description)
        self.assertIn(f"id={episode_uuid('smores56--nix-config', content_hash(normalize_content('A design section')))}", description)

        stored = self.store.lookup("smores56--nix-config", content_hash(normalize_content("A design section")))
        self.assertEqual(stored.source, "sdlc")
        self.assertEqual(stored.source_id, "issue-215#design")

    async def test_source_defaults_to_the_actor_and_source_id_is_empty(self):
        headers = {
            "x-memory-group": "global",
            "x-memory-cwd": "/home/smores/code/example",
            "x-memory-actor": "cli",
        }
        async with create_connected_server_and_client_session(self.build(headers)) as session:
            await session.call_tool("memory_write", {"content": "plain memory"})
        description = self.backend.added[0]["source_description"]
        self.assertIn("source=cli", description)
        self.assertNotIn("source_id=", description)
        stored = self.store.lookup("global", content_hash(normalize_content("plain memory")))
        self.assertEqual(stored.source, "cli")
        self.assertEqual(stored.source_id, "")


class StoreMigrationTests(unittest.TestCase):
    def test_source_id_column_is_added_to_an_old_index(self):
        with tempfile.TemporaryDirectory() as directory:
            db = Path(directory) / DB_NAME
            connection = sqlite3.connect(db)
            connection.executescript(
                """
                CREATE TABLE episodes (
                    group_id TEXT NOT NULL,
                    content_hash TEXT NOT NULL,
                    uuid TEXT NOT NULL,
                    name TEXT NOT NULL,
                    content TEXT NOT NULL,
                    source TEXT NOT NULL,
                    cwd TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    tags TEXT NOT NULL DEFAULT '',
                    status TEXT NOT NULL DEFAULT 'active',
                    promoted_from TEXT,
                    tombstoned_at TEXT,
                    tombstone_reason TEXT,
                    PRIMARY KEY (group_id, content_hash)
                );
                """
            )
            connection.execute(
                "INSERT INTO episodes VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
                ("global", "a" * 64, "uuid", "name", "content", "maki", "/tmp", "2026-01-01T00:00:00Z", "", "active", None, None, None),
            )
            connection.commit()
            connection.close()

            store = Store(directory)
            entry = store.lookup("global", "a" * 64)
            self.assertEqual(entry.source_id, "")

            new = Entry(
                group="global",
                content_hash="b" * 64,
                uuid="uuid2",
                name="name2",
                content="content2",
                source="sdlc",
                cwd="/tmp",
                created_at="2026-01-01T00:00:00Z",
                source_id="issue-1#body",
            )
            self.assertTrue(store.insert(new))
            self.assertEqual(store.lookup("global", "b" * 64), new)

    def test_audit_keeps_json_lines_parseable(self):
        with tempfile.TemporaryDirectory() as directory:
            store = Store(directory)
            store.audit(actor="ingest", group="global", tool="memory_write", status="queued")
            record = json.loads(store.audit_path.read_text())
            self.assertEqual(record["actor"], "ingest")


if __name__ == "__main__":
    unittest.main()
