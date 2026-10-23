import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "modules/features/ai/memory/src"))

from datetime import datetime, timezone  # noqa: E402

from memory_mcp.graph import (  # noqa: E402
    EPISODIC_CONTENTS_QUERY,
    EPISODIC_MATCHES_QUERY,
    RELATES_TO,
    GraphStore,
    GraphUnavailable,
    not_older,
)


class FakeRedis:
    def __init__(self, *, graph_names=("global",), reply=None, error=None, list_error=None, replies=None):
        self.graph_names = graph_names
        self.reply = reply
        self.replies = list(replies or [])
        self.error = error
        self.list_error = list_error
        self.calls = []

    def execute_command(self, *args):
        self.calls.append(args)
        if args[0] == "GRAPH.LIST":
            if self.list_error is not None:
                raise self.list_error
            return [name.encode() for name in self.graph_names]
        if self.replies:
            return self.replies.pop(0)
        if self.error is not None:
            raise self.error
        return self.reply


def reply(rows):
    return [["header"], rows, []]


class GraphPresenceTests(unittest.TestCase):
    def test_presence_returns_the_newest_exact_content_match(self):
        client = FakeRedis(
            graph_names=("owner--repo",),
            reply=reply([["graph-uuid", "2026-01-01T00:00:00Z"]]),
        )
        ref = GraphStore(client=client).episode_for("owner--repo", "the content")
        self.assertEqual(ref.uuid, "graph-uuid")
        self.assertEqual(ref.created_at, "2026-01-01T00:00:00Z")
        _command, graph, query = client.calls[-1]
        self.assertEqual(graph, "owner--repo")
        self.assertTrue(query.startswith('CYPHER g="owner--repo" c="the content" '))
        self.assertIn(EPISODIC_MATCHES_QUERY, query)
        self.assertIn("ORDER BY e.created_at DESC", query)

    def test_content_with_quotes_and_newlines_is_escaped(self):
        client = FakeRedis(graph_names=("global",), reply=reply([]))
        GraphStore(client=client).episode_for("global", 'say "hi"\nnext \\ line')
        query = client.calls[-1][2]
        self.assertIn('c="say \\"hi\\"\\nnext \\\\ line"', query)
        self.assertNotIn("\\u", query)

    def test_every_match_is_returned_newest_first(self):
        client = FakeRedis(
            graph_names=("global",),
            reply=reply(
                [
                    ["ep-new", "2026-02-01T00:00:00Z"],
                    ["ep-old", "2026-01-01T00:00:00Z"],
                ]
            ),
        )
        store = GraphStore(client=client)
        self.assertEqual(store.episode_uuids("global", "c"), ["ep-new", "ep-old"])
        self.assertEqual(store.episode_for("global", "c").uuid, "ep-new")

    def test_a_since_bound_drops_an_episode_that_predates_it(self):
        client = FakeRedis(
            graph_names=("global",),
            reply=reply([["ep-old", "2026-01-01T00:00:00+00:00"]]),
        )
        store = GraphStore(client=client)
        self.assertIsNone(store.episode_for("global", "c", since="2026-01-02T00:00:00Z"))
        # Tombstoning counts on the unbounded helpers still seeing it.
        self.assertEqual(store.episode_uuids("global", "c"), ["ep-old"])

    def test_a_since_bound_keeps_an_episode_at_or_after_it(self):
        client = FakeRedis(
            graph_names=("global",),
            reply=reply(
                [
                    ["ep-new", "2026-01-02T00:00:00+00:00"],
                    ["ep-old", "2026-01-01T00:00:00Z"],
                ]
            ),
        )
        ref = GraphStore(client=client).episode_for("global", "c", since="2026-01-01T12:00:00Z")
        self.assertEqual(ref.uuid, "ep-new")

    def test_a_missing_graph_has_no_matches(self):
        client = FakeRedis(graph_names=("other",))
        self.assertEqual(GraphStore(client=client).episode_uuids("global", "c"), [])
        self.assertEqual(client.calls, [("GRAPH.LIST",)])

    def test_a_missing_graph_is_empty_and_is_not_created_by_a_query(self):
        client = FakeRedis(graph_names=("global",))
        self.assertIsNone(GraphStore(client=client).episode_for("nope", "x"))
        self.assertEqual(client.calls, [("GRAPH.LIST",)])

    def test_a_trailing_backslash_does_not_escape_the_closing_quote(self):
        client = FakeRedis(graph_names=("global",), reply=reply([]))
        GraphStore(client=client).episode_for("global", "path C:\\")
        self.assertIn('c="path C:\\\\"', client.calls[-1][2])

    def test_a_literal_unicode_escape_is_not_decoded(self):
        client = FakeRedis(graph_names=("global",), reply=reply([]))
        GraphStore(client=client).episode_for("global", "literal \\u0000 escape")
        query = client.calls[-1][2]
        self.assertIn('c="literal \\\\u0000 escape"', query)

    def test_unknown_content_is_absent(self):
        client = FakeRedis(graph_names=("global",), reply=reply([]))
        self.assertIsNone(GraphStore(client=client).episode_for("global", "x"))

    def test_contents_groups_timestamps_by_content(self):
        client = FakeRedis(
            graph_names=("owner--repo",),
            reply=reply(
                [
                    ["a", "2026-01-01T00:00:00Z"],
                    ["a", "2026-01-02T00:00:00Z"],
                    ["b", None],
                ]
            ),
        )
        contents = GraphStore(client=client).contents("owner--repo")
        self.assertEqual(contents["a"], ("2026-01-01T00:00:00Z", "2026-01-02T00:00:00Z"))
        self.assertEqual(contents["b"], ("",))
        _command, graph, query = client.calls[-1]
        self.assertEqual(graph, "owner--repo")
        self.assertIn(EPISODIC_CONTENTS_QUERY, query)

    def test_contents_of_a_missing_graph_is_empty(self):
        client = FakeRedis(graph_names=("global",))
        self.assertEqual(GraphStore(client=client).contents("owner--repo"), {})
        self.assertEqual([call[0] for call in client.calls], ["GRAPH.LIST"])

    def test_contents_raises_when_the_database_is_unreachable(self):
        client = FakeRedis(list_error=RuntimeError("connection refused"))
        with self.assertRaises(GraphUnavailable):
            GraphStore(client=client).contents("owner--repo")

    def test_not_older_treats_an_unreadable_stamp_as_no_match(self):
        bound = datetime(2026, 1, 1, tzinfo=timezone.utc)
        self.assertTrue(not_older("2026-01-02T00:00:00Z", bound))
        self.assertFalse(not_older("", bound))
        self.assertFalse(not_older("not-a-time", bound))
        self.assertTrue(not_older("", None))

    def test_an_unknown_graph_error_is_an_empty_group(self):
        client = FakeRedis(
            graph_names=("nope",), error=RuntimeError("ERR Invalid graph name 'nope'")
        )
        self.assertIsNone(GraphStore(client=client).episode_for("nope", "x"))

    def test_an_unreachable_database_raises_graph_unavailable(self):
        client = FakeRedis(list_error=ConnectionError("connection refused"))
        with self.assertRaises(GraphUnavailable):
            GraphStore(client=client).episode_for("global", "x")


class TombstoneTests(unittest.TestCase):
    def test_exclusive_edges_are_invalidated_and_shared_edges_detached(self):
        client = FakeRedis(
            graph_names=("global",),
            replies=[reply([[2]]), reply([[3]])],
        )
        result = GraphStore(client=client).tombstone(
            "global", "ep-1", now="2026-01-01T00:00:00Z"
        )
        self.assertEqual((result.invalidated, result.shared), (2, 3))
        exclusive_query = client.calls[-2][2]
        shared_query = client.calls[-1][2]
        self.assertIn('ep="ep-1"', exclusive_query)
        self.assertIn('now="2026-01-01T00:00:00Z"', exclusive_query)
        self.assertIn('ep="ep-1"', shared_query)
        self.assertIn(f"r:{RELATES_TO}", exclusive_query)
        self.assertIn("size(r.episodes) <= 1", exclusive_query)
        self.assertIn("size(r.episodes) > 1", shared_query)

    def test_a_missing_graph_has_no_edges(self):
        client = FakeRedis(graph_names=("other",))
        result = GraphStore(client=client).tombstone("global", "ep-1", now="now")
        self.assertEqual((result.invalidated, result.shared), (0, 0))
        self.assertEqual(client.calls, [("GRAPH.LIST",)])

    def test_the_edge_type_constant_is_relates_to(self):
        self.assertEqual(RELATES_TO, "RELATES_TO")


if __name__ == "__main__":
    unittest.main()
