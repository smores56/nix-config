import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "modules/features/ai/memory/src"))

from memory_mcp.graph_index import (  # noqa: E402
    EPISODIC_QUERY,
    GraphIndex,
    matches,
    parse_description,
)


class FakeRedis:
    def __init__(self, *, graph_names=("global",), reply=None, error=None, list_error=None):
        self.graph_names = graph_names
        self.reply = reply
        self.error = error
        self.list_error = list_error
        self.calls = []

    def execute_command(self, *args):
        self.calls.append(args)
        if args[0] == "GRAPH.LIST":
            if self.list_error is not None:
                raise self.list_error
            return [name.encode() for name in self.graph_names]
        if self.error is not None:
            raise self.error
        return self.reply


class GraphIndexTests(unittest.TestCase):
    def test_one_query_per_group_returns_every_description(self):
        client = FakeRedis(
            graph_names=("smores56--nix-config",),
            reply=[
                ["e.uuid", "e.source_description"],
                [
                    ["12345678-1234-1234-1234-1234567890ab", "hash=aa; id=12345678-1234-1234-1234-1234567890ab"],
                    ["12345678-1234-1234-1234-1234567890ac", "hash=bb"],
                ],
                [],
            ],
        )
        index = GraphIndex(client=client)
        descriptions = index.descriptions("smores56--nix-config")
        self.assertEqual(len(descriptions), 2)
        self.assertEqual(
            client.calls,
            [
                ("GRAPH.LIST",),
                ("GRAPH.QUERY", "smores56--nix-config", EPISODIC_QUERY),
            ],
        )

    def test_bulk_string_bytes_are_decoded(self):
        digest = "a" * 64
        description = f"hash={digest}; source=sdlc; source_id=issue-1#body"
        client = FakeRedis(
            reply=[
                [b"e.uuid", b"e.source_description"],
                [[b"12345678-1234-1234-1234-1234567890ab", description.encode()]],
                [],
            ]
        )
        descriptions = GraphIndex(client=client).descriptions("global")
        self.assertEqual(descriptions, {description})
        provenance = parse_description(next(iter(descriptions)))
        self.assertTrue(matches(provenance, digest=digest))
        self.assertEqual(provenance.source_id, "issue-1#body")

    def test_a_missing_graph_is_empty_and_is_not_created_by_a_query(self):
        client = FakeRedis(graph_names=("global",))
        self.assertEqual(GraphIndex(client=client).descriptions("nope"), set())
        self.assertEqual(client.calls, [("GRAPH.LIST",)])

    def test_an_unknown_graph_error_is_an_empty_group(self):
        client = FakeRedis(
            graph_names=("nope",), error=RuntimeError("ERR Invalid graph name 'nope'")
        )
        self.assertEqual(GraphIndex(client=client).descriptions("nope"), set())

    def test_an_unreachable_database_is_none(self):
        client = FakeRedis(list_error=ConnectionError("connection refused"))
        self.assertIsNone(GraphIndex(client=client).descriptions("global"))

    def test_a_missing_redis_module_is_none(self):
        index = GraphIndex()
        index._redis = lambda: (_ for _ in ()).throw(ImportError("no redis"))
        self.assertIsNone(index.descriptions("global"))

    def test_matches_requires_the_exact_version(self):
        provenance = parse_description(
            "hash={hash}; id=12345678-1234-1234-1234-1234567890ab; source=sdlc; source_id=issue-1#body".format(
                hash="a" * 64
            )
        )
        self.assertTrue(matches(provenance, uid="12345678-1234-1234-1234-1234567890ab"))
        self.assertTrue(matches(provenance, digest="a" * 64))
        self.assertFalse(matches(provenance, uid="00000000-0000-0000-0000-000000000000", digest="b" * 64))
        # A previous version of the same plan entry must not look present.
        self.assertFalse(matches(provenance, source="sdlc", source_id="issue-1#body"))

    def test_a_legacy_description_without_a_hash_can_match_its_source(self):
        provenance = parse_description("source=sdlc; source_id=issue-1#body")
        self.assertTrue(matches(provenance, source="sdlc", source_id="issue-1#body"))
        self.assertFalse(matches(provenance, source="sdlc", source_id="issue-2#body"))

    def test_partial_source_fields_do_not_match(self):
        provenance = parse_description("source=sdlc")
        self.assertFalse(matches(provenance, source="sdlc", source_id="issue-1#body"))


if __name__ == "__main__":
    unittest.main()
