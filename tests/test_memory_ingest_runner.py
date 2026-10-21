import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "modules/features/ai/memory/src"))

from memory_mcp.client import ToolResult  # noqa: E402
from memory_mcp.graphiti import BackendError  # noqa: E402
from memory_mcp.ingest_runner import IngestError, IngestRunner, RunnerConfig  # noqa: E402
from memory_mcp.ingest_sources import Episode, Plan, Skip  # noqa: E402
from memory_mcp.normalize import content_hash, episode_uuid, normalize_content  # noqa: E402


class FakeGraph:
    def __init__(self):
        self.descriptions = []
        self.status_ok = True
        self.verify_calls = 0

    async def get_status(self):
        if not self.status_ok:
            raise BackendError("connection refused")
        return {"status": "ok"}

    async def get_episodes(self, group_ids, max_episodes):
        self.verify_calls += 1
        return [
            {"source_description": description}
            for group, description in self.descriptions
            if group in group_ids
        ][:max_episodes]


class FakeWrapper:
    def __init__(self, graph, *, drop=()):
        self.graph = graph
        self.drop = set(drop)
        self.dropped = set()
        self.calls = []
        self.active = {}
        self.tombstoned = set()
        self.write_headers = []
        self.batches = []
        self._since_verify = 0

    async def __call__(self, config, tool, arguments):
        headers = {key.lower(): value for key, value in config.header_dict().items()}
        self.calls.append(tool)
        group = headers["x-memory-group"]
        if tool == "memory_status":
            return ToolResult(text="Memory status", is_error=False)
        if tool == "memory_tombstone":
            for key, uid in self.active.items():
                if uid == arguments["ref"]:
                    self.tombstoned.add(key)
            return ToolResult(text="tombstoned", is_error=False)
        if tool == "memory_write":
            content = normalize_content(arguments["content"])
            digest = content_hash(content)
            key = (group, digest)
            uid = episode_uuid(group, digest)
            self.write_headers.append(headers)
            self._since_verify += 1
            if key in self.active and key not in self.tombstoned:
                return ToolResult(
                    text=f"Duplicate memory: the same content is already stored in group {group} as {uid}.",
                    is_error=False,
                )
            self.active[key] = uid
            self.tombstoned.discard(key)
            source_id = headers.get("x-memory-source-id", "")
            if source_id in self.drop and source_id not in self.dropped:
                self.dropped.add(source_id)
            else:
                self.graph.descriptions.append(
                    (
                        group,
                        "hash={}; actor=ingest; source={}; source_id={}; id={}".format(
                            digest,
                            headers.get("x-memory-source", ""),
                            source_id,
                            uid,
                        ),
                    )
                )
            self.batches.append(self._since_verify)
            return ToolResult(text=f"Queued memory {uid} in group {group}.", is_error=False)
        raise AssertionError(f"unexpected tool {tool}")


def episodes(count=1, *, source="sdlc", group="smores56--sdlc", prefix="issue-1"):
    return [
        Episode(
            source=source,
            source_id=f"{prefix}#section-{index}",
            group=group,
            content=f"## Section {index}\n\n" + f"body {index} " * 20,
        )
        for index in range(1, count + 1)
    ]


class RunnerTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.graph = FakeGraph()
        self.wrapper = FakeWrapper(self.graph)
        self.report_path = str(Path(self.tmp.name, "report.json"))
        self.state_path = str(Path(self.tmp.name, "state.json"))

    def tearDown(self):
        self.tmp.cleanup()

    def config(self, **overrides):
        values = dict(
            wrapper_url="http://wrapper/mcp",
            graphiti_url="http://graphiti/mcp",
            cwd="/home/smores",
            batch=2,
            verify_timeout=0,
            poll_seconds=0,
            report_path=self.report_path,
            state_path=self.state_path,
        )
        values.update(overrides)
        return RunnerConfig(**values)

    def runner(self, config=None, wrapper=None):
        return IngestRunner(
            config or self.config(),
            backend=self.graph,
            call_tool_fn=wrapper or self.wrapper,
        )

    async def test_batches_writes_verifies_and_counts(self):
        plan = Plan(source="sdlc", episodes=episodes(5))
        report = await self.runner().run([plan])
        totals = report["totals"]
        self.assertEqual(totals["built"], 5)
        self.assertEqual(totals["queued"], 5)
        self.assertEqual(totals["verified"], 5)
        self.assertEqual(totals["failed"], 0)
        self.assertEqual(report["sources"]["sdlc"]["groups"]["smores56--sdlc"]["verified"], 5)
        self.assertEqual(self.graph.verify_calls, 3)
        stored = json.loads(Path(self.report_path).read_text())
        self.assertEqual(stored["totals"]["verified"], 5)
        state = json.loads(Path(self.state_path).read_text())
        self.assertEqual(len(state["verified"]), 5)

    async def test_provenance_headers_carry_the_source_and_id(self):
        await self.runner().run([Plan(source="sdlc", episodes=episodes(1))])
        headers = self.wrapper.write_headers[0]
        self.assertEqual(headers["x-memory-group"], "smores56--sdlc")
        self.assertEqual(headers["x-memory-source"], "sdlc")
        self.assertEqual(headers["x-memory-source-id"], "issue-1#section-1")
        self.assertEqual(headers["x-memory-actor"], "ingest")

    async def test_same_content_twice_is_a_duplicate_but_still_verified(self):
        plan = Plan(
            source="sdlc",
            episodes=[
                Episode(source="sdlc", source_id="issue-1#a", group="smores56--sdlc", content="same " * 30),
                Episode(source="sdlc", source_id="issue-1#b", group="smores56--sdlc", content="same " * 30),
            ],
        )
        report = await self.runner().run([plan])
        totals = report["totals"]
        self.assertEqual(totals["queued"], 1)
        self.assertEqual(totals["duplicate"], 1)
        self.assertEqual(totals["verified"], 2)
        self.assertEqual(report["duplicate_rate"], 0.5)

    async def test_missing_episode_is_tombstoned_and_rewritten_once(self):
        self.wrapper = FakeWrapper(self.graph, drop={"issue-1#section-2"})
        plan = Plan(source="sdlc", episodes=episodes(2))
        report = await self.runner().run([plan])
        totals = report["totals"]
        self.assertEqual(totals["repaired"], 1)
        self.assertEqual(totals["verified"], 2)
        self.assertEqual(totals["failed"], 0)
        self.assertIn("memory_tombstone", self.wrapper.calls)
        self.assertEqual(len([call for call in self.wrapper.calls if call == "memory_write"]), 3)

    async def test_persistent_missing_episode_is_a_failure(self):
        self.wrapper = FakeWrapper(self.graph, drop={"issue-1#section-1", "issue-1#section-1"})
        # The durable drop keeps both the first write and the repair out of the graph.
        self.wrapper.drop = {"issue-1#section-1"}
        self.wrapper.dropped = set()
        original = self.wrapper.__call__

        async def always_drop(config, tool, arguments):
            if tool == "memory_write":
                self.wrapper.dropped.discard("issue-1#section-1")
            return await original(config, tool, arguments)

        report = await self.runner(wrapper=always_drop).run([Plan(source="sdlc", episodes=episodes(1))])
        self.assertEqual(report["totals"]["failed"], 1)
        self.assertEqual(report["failures"][0]["source_id"], "issue-1#section-1")
        self.assertIn("still missing", report["failures"][0]["error"])

    async def test_state_skips_verified_episodes_on_a_rerun(self):
        plan = Plan(source="sdlc", episodes=episodes(3))
        await self.runner().run([plan])
        writes = len(self.wrapper.write_headers)
        second = await self.runner().run([plan])
        self.assertEqual(len(self.wrapper.write_headers), writes)
        self.assertEqual(second["totals"]["skipped"], 3)
        self.assertEqual(second["totals"]["queued"], 0)

    async def test_dry_run_prints_the_plan_and_writes_nothing(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            report = await self.runner(self.config(dry_run=True)).run(
                [Plan(source="sdlc", episodes=episodes(2), skipped=[Skip("sdlc", "issue-9", "work")])]
            )
        self.assertEqual(self.wrapper.write_headers, [])
        self.assertFalse(Path(self.report_path).exists())
        self.assertFalse(Path(self.state_path).exists())
        self.assertEqual(report["totals"]["built"], 2)
        self.assertEqual(report["totals"]["skipped"], 1)
        printed = out.getvalue()
        self.assertIn("ingest plan (dry run)", printed)
        self.assertIn("issue-1#section-1", printed)

    async def test_unreachable_raw_graphiti_fails_with_smortress_guidance(self):
        self.graph.status_ok = False
        with self.assertRaises(IngestError) as caught:
            await self.runner().run([Plan(source="sdlc", episodes=episodes(1))])
        self.assertIn("smortress", str(caught.exception))
        self.assertEqual(self.wrapper.write_headers, [])

    async def test_episodes_with_same_source_id_are_skipped_within_a_run(self):
        plan = Plan(
            source="notes",
            episodes=[
                Episode(source="notes", source_id="note:a.md#x", group="global", content="a" * 100),
                Episode(source="notes", source_id="note:a.md#x", group="global", content="b" * 100),
            ],
        )
        report = await self.runner().run([plan])
        self.assertEqual(report["totals"]["skipped"], 1)
        self.assertEqual(len(self.wrapper.write_headers), 1)


if __name__ == "__main__":
    unittest.main()
