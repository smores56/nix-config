import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "modules/features/ai/memory/src"))

from memory_mcp.client import ToolResult  # noqa: E402
from memory_mcp.graph_index import Provenance, parse_description  # noqa: E402
from memory_mcp.graphiti import BackendError  # noqa: E402
from memory_mcp.ingest_runner import (  # noqa: E402
    DEFAULT_BATCH,
    DEFAULT_VERIFY_TIMEOUT,
    IngestError,
    IngestRunner,
    IngestState,
    RunnerConfig,
)
from memory_mcp.ingest_sources import Episode, Plan, Skip  # noqa: E402
from memory_mcp.normalize import content_hash, episode_uuid, normalize_content  # noqa: E402


class FakeGraph:
    """The FalkorDB descriptions plus the Graphiti `get_episodes` fallback."""

    def __init__(self):
        self.descriptions: dict[str, set[str]] = {}
        self.status_ok = True
        self.redis_ok = True
        self.unavailable_groups: set[str] = set()
        self.fail_groups: set[str] = set()
        self.verify_calls = 0
        self.fetch_sizes = []

    def add(self, group, description):
        self.descriptions.setdefault(group, set()).add(description)

    async def get_status(self):
        if not self.status_ok:
            raise BackendError("connection refused")
        return {"status": "ok"}

    async def get_episodes(self, group_ids, max_episodes):
        self.verify_calls += 1
        self.fetch_sizes.append(max_episodes)
        if self.fail_groups & set(group_ids):
            raise BackendError("get_episodes unavailable")
        return [
            {"source_description": description}
            for group in group_ids
            for description in sorted(self.descriptions.get(group, set()))
        ][:max_episodes]


class FakeIndex:
    def __init__(self, graph):
        self.graph = graph
        self.url = "redis://fake:6379"
        self.calls = []

    def descriptions(self, group):
        self.calls.append(group)
        if not self.graph.redis_ok or group in self.graph.unavailable_groups:
            return None
        return set(self.graph.descriptions.get(group, set()))


class FakeWrapper:
    def __init__(self, graph, *, drop=(), drop_always=()):
        self.graph = graph
        self.drop = set(drop)
        self.drop_always = set(drop_always)
        self.dropped = set()
        self.calls = []
        self.write_arguments = []
        self.write_headers = []
        self.active = {}
        self.tombstoned = set()

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
            return ToolResult(
                text=f"no stored episode in group {group} matches {arguments['ref']!r}; "
                "use a uuid, content hash prefix, or exact name",
                is_error=True,
            )
        if tool == "memory_write":
            content = normalize_content(arguments["content"])
            digest = content_hash(content)
            key = (group, digest)
            uid = episode_uuid(group, digest)
            self.write_headers.append(headers)
            self.write_arguments.append(arguments)
            if key in self.active and key not in self.tombstoned:
                return ToolResult(
                    text=f"Duplicate memory: the same content is already stored in group {group} as {uid}.",
                    is_error=False,
                )
            self.active[key] = uid
            self.tombstoned.discard(key)
            source_id = headers.get("x-memory-source-id", "")
            dropped = source_id in self.drop_always or (
                source_id in self.drop and source_id not in self.dropped
            )
            if source_id in self.drop:
                self.dropped.add(source_id)
            if not dropped:
                self.graph.add(
                    group,
                    "hash={}; id={}; cwd=/home/smores; actor=ingest; source={}; source_id={}".format(
                        digest,
                        uid,
                        headers.get("x-memory-source", ""),
                        source_id,
                    ),
                )
            return ToolResult(text=f"Queued memory {uid} in group {group}.", is_error=False)
        raise AssertionError(f"unexpected tool {tool}")


def episodes(count=1, *, source="sdlc", group="smores56--sdlc", prefix="issue-1"):
    return [
        Episode(
            source=source,
            source_id=f"{prefix}#section-{index}",
            group=group,
            content=f"## Section {index}\n\n" + f"body {index} " * 20,
            tags=("sdlc", "issue-1"),
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
            index=FakeIndex(self.graph),
        )

    async def run_quiet(self, runner, plans, **kwargs):
        with contextlib.redirect_stderr(io.StringIO()) as stderr:
            report = await runner.run(plans, **kwargs)
        return report, stderr.getvalue()

    async def test_defaults_are_one_at_a_time_and_a_ten_minute_grace(self):
        self.assertEqual(RunnerConfig().batch, DEFAULT_BATCH)
        self.assertEqual(DEFAULT_BATCH, 1)
        self.assertEqual(RunnerConfig().verify_timeout, DEFAULT_VERIFY_TIMEOUT)
        self.assertEqual(DEFAULT_VERIFY_TIMEOUT, 600.0)

    async def test_batches_writes_verifies_and_counts(self):
        plan = Plan(source="sdlc", episodes=episodes(5))
        report, _err = await self.run_quiet(self.runner(), [plan])
        totals = report["totals"]
        self.assertEqual(totals["built"], 5)
        self.assertEqual(totals["queued"], 5)
        self.assertEqual(totals["verified"], 5)
        self.assertEqual(totals["failed"], 0)
        self.assertEqual(report["sources"]["sdlc"]["groups"]["smores56--sdlc"]["verified"], 5)
        stored = json.loads(Path(self.report_path).read_text())
        self.assertEqual(stored["totals"]["verified"], 5)
        state = json.loads(Path(self.state_path).read_text())
        self.assertEqual(state["version"], 2)
        self.assertEqual(len(state["entries"]), 5)
        self.assertTrue(all(entry["status"] == "verified" for entry in state["entries"].values()))

    async def test_verification_reads_falkordb_and_never_pages_get_episodes(self):
        report, _err = await self.run_quiet(self.runner(), [Plan(source="sdlc", episodes=episodes(2))])
        self.assertEqual(report["totals"]["verified"], 2)
        self.assertEqual(self.graph.verify_calls, 0)
        self.assertEqual(report["presence"], "falkordb")

    async def test_redis_unavailable_falls_back_to_get_episodes_and_says_so(self):
        self.graph.redis_ok = False
        report, stderr = await self.run_quiet(self.runner(), [Plan(source="sdlc", episodes=episodes(1))])
        self.assertEqual(report["totals"]["verified"], 1)
        self.assertEqual(report["presence"], "get_episodes")
        self.assertGreater(self.graph.verify_calls, 0)
        self.assertIn("FalkorDB", stderr)
        self.assertIn("get_episodes", stderr)

    async def test_provenance_headers_carry_the_source_and_id(self):
        await self.run_quiet(self.runner(), [Plan(source="sdlc", episodes=episodes(1))])
        headers = self.wrapper.write_headers[0]
        self.assertEqual(headers["x-memory-group"], "smores56--sdlc")
        self.assertEqual(headers["x-memory-source"], "sdlc")
        self.assertEqual(headers["x-memory-source-id"], "issue-1#section-1")
        self.assertEqual(headers["x-memory-actor"], "ingest")

    async def test_tags_are_passed_to_memory_write(self):
        await self.run_quiet(self.runner(), [Plan(source="sdlc", episodes=episodes(1))])
        self.assertEqual(self.wrapper.write_arguments[0]["tags"], ["sdlc", "issue-1"])

    async def test_same_content_twice_is_a_duplicate_but_still_verified(self):
        plan = Plan(
            source="sdlc",
            episodes=[
                Episode(source="sdlc", source_id="issue-1#a", group="smores56--sdlc", content="same " * 30),
                Episode(source="sdlc", source_id="issue-1#b", group="smores56--sdlc", content="same " * 30),
            ],
        )
        report, _err = await self.run_quiet(self.runner(), [plan])
        totals = report["totals"]
        self.assertEqual(totals["queued"], 1)
        self.assertEqual(totals["duplicate"], 1)
        self.assertEqual(totals["verified"], 2)
        self.assertEqual(report["duplicate_rate"], 0.5)

    async def test_first_run_never_reconciles_or_tombstones(self):
        self.graph.add("smores56--sdlc", "hash={}; id={}; source=sdlc; source_id=other".format("0" * 64, "0" * 36))
        report, stderr = await self.run_quiet(self.runner(), [Plan(source="sdlc", episodes=episodes(2))])
        self.assertNotIn("memory_tombstone", self.wrapper.calls)
        self.assertEqual(report["totals"]["reconciled"], 0)
        self.assertIn("first run", stderr)
        # Presence is not read for reconcile before the first write.
        self.assertEqual(self.graph.verify_calls, 0)

    async def test_absent_episode_is_a_failure_and_not_rewritten(self):
        self.wrapper = FakeWrapper(self.graph, drop={"issue-1#section-1"})
        report, _err = await self.run_quiet(self.runner(), [Plan(source="sdlc", episodes=episodes(1))])
        self.assertEqual(report["totals"]["failed"], 1)
        self.assertEqual(report["totals"]["repaired"], 0)
        self.assertNotIn("memory_tombstone", self.wrapper.calls)
        self.assertEqual(len(self.wrapper.write_arguments), 1)
        self.assertIn("grace", report["failures"][0]["error"])
        self.assertIn("--repair", report["failures"][0]["error"])

    async def test_repair_is_opt_in_and_needs_a_prior_attempt(self):
        self.wrapper = FakeWrapper(self.graph, drop={"issue-1#section-1"})
        report, _err = await self.run_quiet(
            self.runner(self.config(repair=True)), [Plan(source="sdlc", episodes=episodes(1))]
        )
        self.assertEqual(report["totals"]["repaired"], 0)
        self.assertEqual(report["totals"]["failed"], 1)
        self.assertNotIn("memory_tombstone", self.wrapper.calls)
        self.assertEqual(len(self.wrapper.write_arguments), 1)

    async def test_repair_rewrites_an_absent_previously_attempted_episode_once(self):
        plan = Plan(source="sdlc", episodes=episodes(1))
        self.wrapper = FakeWrapper(self.graph, drop_always={"issue-1#section-1"})
        first, _err = await self.run_quiet(self.runner(), [plan])
        self.assertEqual(first["totals"]["failed"], 1)

        self.wrapper = FakeWrapper(self.graph, drop={"issue-1#section-1"})
        second, _err = await self.run_quiet(
            self.runner(self.config(repair=True)), [plan]
        )
        totals = second["totals"]
        self.assertEqual(totals["reconciled"], 1)
        self.assertEqual(totals["repaired"], 1)
        self.assertEqual(totals["verified"], 1)
        self.assertEqual(totals["failed"], 0)
        self.assertEqual(self.wrapper.calls.count("memory_write"), 2)
        self.assertEqual(self.wrapper.calls.count("memory_tombstone"), 2)

    async def test_repair_refuses_an_approximate_absence(self):
        plan = Plan(source="sdlc", episodes=episodes(1))
        self.wrapper = FakeWrapper(self.graph, drop_always={"issue-1#section-1"})
        await self.run_quiet(self.runner(), [plan])

        self.graph.redis_ok = False
        self.wrapper = FakeWrapper(self.graph, drop={"issue-1#section-1"})
        report, stderr = await self.run_quiet(
            self.runner(self.config(repair=True)), [plan]
        )
        self.assertEqual(report["totals"]["repaired"], 0)
        self.assertEqual(report["totals"]["failed"], 1)
        # Only the reconcile tombstone (from the fallback absence), never a repair.
        self.assertEqual(self.wrapper.calls.count("memory_tombstone"), 1)
        self.assertIn("FalkorDB unavailable", stderr)

    async def test_state_skips_verified_episodes_on_a_rerun(self):
        plan = Plan(source="sdlc", episodes=episodes(3))
        await self.run_quiet(self.runner(), [plan])
        writes = len(self.wrapper.write_headers)
        second, _err = await self.run_quiet(self.runner(), [plan])
        self.assertEqual(len(self.wrapper.write_headers), writes)
        self.assertEqual(second["totals"]["skipped"], 3)
        self.assertEqual(second["totals"]["queued"], 0)

    async def test_a_moved_source_writes_to_its_new_group(self):
        first = Plan(
            source="sdlc",
            episodes=[Episode(source="sdlc", source_id="issue-5#body", group="smores56--a", content="task " * 30)],
        )
        await self.run_quiet(self.runner(), [first])
        moved = Plan(
            source="sdlc",
            episodes=[Episode(source="sdlc", source_id="issue-5#body", group="smores56--b", content="task " * 30)],
        )
        second, _err = await self.run_quiet(self.runner(), [moved])
        self.assertEqual(second["totals"]["skipped"], 0)
        self.assertEqual(second["totals"]["queued"], 1)
        self.assertEqual(second["totals"]["verified"], 1)
        self.assertEqual(self.wrapper.write_headers[-1]["x-memory-group"], "smores56--b")

    async def test_a_changed_hash_supersedes_the_old_index_row(self):
        original = Plan(
            source="notes",
            episodes=[Episode(source="notes", source_id="note:a.md#body", group="global", content="old " * 40)],
        )
        await self.run_quiet(self.runner(), [original])
        old_uid = episode_uuid("global", content_hash(normalize_content("old " * 40)))

        changed = Plan(
            source="notes",
            episodes=[Episode(source="notes", source_id="note:a.md#body", group="global", content="new " * 40)],
        )
        report, _err = await self.run_quiet(self.runner(), [changed])
        self.assertEqual(report["totals"]["superseded"], 1)
        self.assertEqual(report["totals"]["queued"], 1)
        self.assertEqual(report["totals"]["verified"], 1)
        self.assertIn(old_uid, [uid for key, uid in self.wrapper.active.items()])
        state = json.loads(Path(self.state_path).read_text())
        entry = next(iter(state["entries"].values()))
        self.assertEqual(entry["status"], "verified")
        self.assertEqual(entry["hash"], content_hash(normalize_content("new " * 40)))
        # The old graph episode remains by design (there is no graph-level delete).
        self.assertEqual(len(self.graph.descriptions["global"]), 2)

    async def test_a_new_version_is_not_adopted_from_the_old_episode(self):
        original = Plan(
            source="notes",
            episodes=[Episode(source="notes", source_id="note:a.md#body", group="global", content="old " * 40)],
        )
        await self.run_quiet(self.runner(), [original])

        changed = Plan(
            source="notes",
            episodes=[Episode(source="notes", source_id="note:a.md#body", group="global", content="new " * 40)],
        )
        self.wrapper = FakeWrapper(self.graph, drop={"note:a.md#body"})
        first, _err = await self.run_quiet(self.runner(), [changed])
        self.assertEqual(first["totals"]["failed"], 1)

        # Same source_id, different content, old version still in the graph:
        # the new version must not be adopted from the old episode.
        self.wrapper = FakeWrapper(self.graph)
        second, _err = await self.run_quiet(self.runner(), [changed])
        self.assertEqual(second["totals"]["adopted"], 0)
        self.assertEqual(second["totals"]["reconciled"], 1)
        self.assertEqual(second["totals"]["queued"], 1)
        self.assertEqual(second["totals"]["verified"], 1)
        self.assertEqual(len(self.graph.descriptions["global"]), 2)

    async def test_reconcile_revives_rows_that_never_reached_the_graph(self):
        plan = Plan(source="sdlc", episodes=episodes(2))
        self.wrapper = FakeWrapper(self.graph, drop_always={"issue-1#section-1", "issue-1#section-2"})
        first, _err = await self.run_quiet(self.runner(), [plan])
        self.assertEqual(first["totals"]["failed"], 2)
        self.assertEqual(self.graph.descriptions, {})

        self.wrapper = FakeWrapper(self.graph)
        calls_before = len(self.wrapper.calls)
        second, _err = await self.run_quiet(self.runner(), [plan])
        totals = second["totals"]
        self.assertEqual(totals["reconciled"], 2)
        self.assertEqual(totals["queued"], 2)
        self.assertEqual(totals["duplicate"], 0)
        self.assertEqual(totals["verified"], 2)
        self.assertEqual(totals["failed"], 0)
        second_calls = self.wrapper.calls[calls_before:]
        self.assertEqual(second_calls[0], "memory_status")
        self.assertEqual(second_calls[1:3], ["memory_tombstone"] * 2)
        self.assertEqual(second_calls[3:], ["memory_write"] * 2)

    async def test_reconcile_adopts_an_episode_that_landed_late(self):
        plan = Plan(source="sdlc", episodes=episodes(1))
        self.wrapper = FakeWrapper(self.graph, drop_always={"issue-1#section-1"})
        await self.run_quiet(self.runner(), [plan])

        entry = episodes(1)[0]
        digest = content_hash(normalize_content(entry.content))
        uid = episode_uuid(entry.group, digest)
        self.graph.add(entry.group, f"hash={digest}; id={uid}; source=sdlc; source_id={entry.source_id}")

        self.wrapper = FakeWrapper(self.graph)
        report, _err = await self.run_quiet(self.runner(), [plan])
        self.assertEqual(report["totals"]["adopted"], 1)
        self.assertEqual(report["totals"]["queued"], 0)
        self.assertEqual(self.wrapper.write_arguments, [])

    async def test_reconcile_is_per_group_and_does_not_early_return(self):
        plan = Plan(
            source="sdlc",
            episodes=[
                Episode(source="sdlc", source_id="issue-1#a", group="smores56--a", content="a " * 40),
                Episode(source="sdlc", source_id="issue-2#b", group="smores56--b", content="b " * 40),
            ],
        )
        self.wrapper = FakeWrapper(self.graph, drop_always={"issue-1#a", "issue-2#b"})
        await self.run_quiet(self.runner(), [plan])

        self.graph.redis_ok = False
        self.graph.fail_groups = {"smores56--a"}
        self.wrapper = FakeWrapper(self.graph)
        report, _err = await self.run_quiet(self.runner(), [plan])

        self.assertEqual(report["totals"]["reconciled"], 1)
        self.assertEqual(report["totals"]["queued"], 1)
        self.assertEqual(report["totals"]["verified"], 1)
        failed = {failure["group"] for failure in report["failures"]}
        self.assertEqual(failed, {"smores56--a"})

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

    async def test_json_dry_run_keeps_the_plan_off_stdout(self):
        out = io.StringIO()
        err = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            await self.runner(self.config(dry_run=True, json_output=True)).run(
                [Plan(source="sdlc", episodes=episodes(1))]
            )
        self.assertEqual(out.getvalue(), "")
        self.assertIn("ingest plan (dry run)", err.getvalue())

    async def test_unreachable_raw_graphiti_fails_with_smortress_guidance(self):
        self.graph.status_ok = False
        with self.assertRaises(IngestError) as caught:
            await self.run_quiet(self.runner(), [Plan(source="sdlc", episodes=episodes(1))])
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
        report, _err = await self.run_quiet(self.runner(), [plan])
        self.assertEqual(report["totals"]["skipped"], 1)
        self.assertEqual(len(self.wrapper.write_headers), 1)

    async def test_state_file_is_locked_against_a_second_run(self):
        state = IngestState(Path(self.state_path))
        with state.lock():
            with self.assertRaises(IngestError) as caught:
                await self.run_quiet(self.runner(), [Plan(source="sdlc", episodes=episodes(1))])
        self.assertIn("another ingest", str(caught.exception))

    async def test_reset_state_archives_and_requires_force(self):
        plan = Plan(source="sdlc", episodes=episodes(1))
        await self.run_quiet(self.runner(), [plan])
        self.assertTrue(Path(self.state_path).exists())

        with self.assertRaises(IngestError):
            await self.run_quiet(self.runner(self.config(reset_state=True)), [plan])
        with self.assertRaises(IngestError):
            await self.run_quiet(self.runner(self.config(force=True)), [plan])

        writes = len(self.wrapper.write_headers)
        report, _err = await self.run_quiet(
            self.runner(self.config(force=True, reset_state=True)), [plan]
        )
        # The reset re-attempts the same content; the wrapper index still holds
        # it, so the write is a duplicate (no second graph episode).
        self.assertEqual(report["totals"]["queued"] + report["totals"]["duplicate"], 1)
        self.assertEqual(len(self.wrapper.write_headers), writes + 1)
        backups = list(Path(self.tmp.name).glob("state.json.bak-*"))
        self.assertEqual(len(backups), 1)

    async def test_source_errors_are_reported_without_aborting(self):
        report, _err = await self.run_quiet(
            self.runner(),
            [Plan(source="notes", episodes=episodes(1, source="notes", group="global", prefix="note:a"))],
            source_errors={"sdlc": "gh is not installed"},
        )
        self.assertEqual(report["sources"]["sdlc"]["error"], "gh is not installed")
        self.assertEqual(report["totals"]["failed"], 1)
        self.assertEqual(report["totals"]["verified"], 1)
        self.assertEqual(report["failures"][0]["source_id"], "*")


class ProvenanceTests(unittest.TestCase):
    def test_tokens_are_parsed_from_the_description(self):
        provenance = parse_description(
            "hash={hash}; id={uid}; cwd=/home/x; actor=ingest; source=sdlc; source_id=issue-1#body".format(
                hash="a" * 64, uid="12345678-1234-1234-1234-1234567890ab"
            )
        )
        self.assertEqual(provenance.hash, "a" * 64)
        self.assertEqual(provenance.id, "12345678-1234-1234-1234-1234567890ab")
        self.assertEqual(provenance.source, "sdlc")
        self.assertEqual(provenance.source_id, "issue-1#body")

    def test_empty_description_matches_nothing(self):
        self.assertEqual(parse_description(""), Provenance())


if __name__ == "__main__":
    unittest.main()
