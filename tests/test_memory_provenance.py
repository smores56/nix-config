import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "modules/features/ai/memory/src"))

from mcp.shared.memory import create_connected_server_and_client_session  # noqa: E402

from memory_mcp.groups import MAX_PROVENANCE_CHARS, sanitize_provenance  # noqa: E402
from memory_mcp.normalize import content_hash, episode_uuid, normalize_content  # noqa: E402
from memory_mcp.registry import Registry, RegistryEpisode  # noqa: E402
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
        self.status = {"status": "ok"}

    async def add_episode(self, **kwargs):
        self.added.append(kwargs)
        return {"message": "episode queued"}

    async def get_status(self):
        return self.status


class FakeProbes:
    async def require_write(self):
        return None

    async def require_search(self):
        return None

    async def failures(self):
        return []


class WrapperProvenanceTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.registry = Registry(self.tmp.name)
        self.backend = FakeBackend()

    def tearDown(self):
        self.tmp.cleanup()

    def build(self, headers):
        return build_server(
            WrapperConfig(state_dir=self.tmp.name, graphiti_url="http://127.0.0.1:1/mcp"),
            backend=self.backend,
            registry=self.registry,
            probes=FakeProbes(),
            headers_provider=lambda _ctx: headers,
            start_reconciler=False,
        )

    def headers(self, **overrides):
        values = {
            "x-memory-group": "smores56--nix-config",
            "x-memory-cwd": "/home/smores/code/example",
            "x-memory-actor": "maki",
        }
        values.update(overrides)
        return values

    async def test_agent_write_is_typed_and_has_a_human_description(self):
        async with create_connected_server_and_client_session(self.build(self.headers())) as session:
            result = await session.call_tool("memory_write", {"content": "A design section", "tags": ["Design"]})
        self.assertFalse(result.isError)
        added = self.backend.added[0]
        self.assertEqual(added["source"], "text")
        self.assertIn("reference_time", added)
        description = added["source_description"]
        self.assertTrue(description.startswith("agent"))
        self.assertNotIn("=", description)
        self.assertNotIn("uuid", added)

        stored = self.registry.lookup(
            "smores56--nix-config", content_hash(normalize_content("A design section"))
        )
        self.assertEqual(stored.kind, "text")
        self.assertEqual(stored.origin, "agent")
        self.assertEqual(stored.actor, "maki")
        self.assertEqual(stored.tags, ("design",))
        self.assertEqual(stored.uuid, episode_uuid("smores56--nix-config", stored.content_hash))
        self.assertEqual(stored.status, "pending")
        self.assertEqual(stored.attempts, 1)

    async def test_get_returns_typed_provenance_for_an_ingested_row(self):
        digest = content_hash("A design section")
        entry = RegistryEpisode(
            group="smores56--nix-config",
            content_hash=digest,
            uuid=episode_uuid("smores56--nix-config", digest),
            name="design",
            content="A design section",
            kind="text",
            origin="sdlc",
            origin_ref="issue-215#design",
            actor="ingest",
            cwd="",
            tags=("sdlc",),
            valid_at="2026-10-03T00:00:00Z",
            created_at="2026-10-04T00:00:00Z",
            status="active",
            graphiti_uuid="graph-1",
        )
        self.registry.insert(entry)
        async with create_connected_server_and_client_session(self.build(self.headers())) as session:
            result = await session.call_tool("memory_get", {"ref": "sdlc:issue-215#design"})
        self.assertFalse(result.isError)
        text = result.content[0].text
        self.assertIn("[sdlc issue-215#design · 2026-10-03]", text)
        self.assertIn(f"Memory {entry.uuid}", text)
        self.assertIn("A design section", text)
        self.assertIn("graph-1", text)

    async def test_no_legacy_index_file_is_created(self):
        self.build(self.headers())
        self.assertTrue((Path(self.tmp.name) / "registry.sqlite").exists())
        self.assertFalse((Path(self.tmp.name) / "index.sqlite").exists())


if __name__ == "__main__":
    unittest.main()
