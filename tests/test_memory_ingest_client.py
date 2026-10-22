import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "modules/features/ai/memory/src"))

from memory_mcp.ingest_runner import IngestError, IngestRunner, RunnerConfig  # noqa: E402
from memory_mcp.ingest_sources import Episode, Plan  # noqa: E402
from memory_mcp.normalize import content_hash, episode_uuid, normalize_content  # noqa: E402


class FakeLookup:
    def __init__(self, statuses=None, *, error=None):
        self.statuses = statuses or {}
        self.error = error
        self.calls = []

    async def __call__(self, group, hashes):
        self.calls.append((group, list(hashes)))
        if self.error:
            raise IngestError(self.error)
        result = {}
        for digest in hashes:
            result[digest] = self.statuses.get(
                (group, digest), {"status": "missing", "uuid": episode_uuid(group, digest)}
            )
        return result


class FakeSubmit:
    def __init__(self, *, error=None):
        self.error = error
        self.payloads = []

    async def __call__(self, payload):
        self.payloads.append(payload)
        if self.error:
            raise IngestError(self.error)
        return {"status": "queued", "uuid": episode_uuid(payload["group"], content_hash(normalize_content(payload["content"])))}


def episode(source_id="issue-1#design", content="a design section", group="owner--repo", **overrides):
    values = {
        "source": "sdlc",
        "source_id": source_id,
        "group": group,
        "content": content,
        "tags": ("sdlc",),
        "kind": "text",
        "valid_at": "2026-10-03T12:00:00Z",
    }
    values.update(overrides)
    return Episode(**values)


class IngestClientTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.report_path = Path(self.tmp.name) / "report.json"

    def tearDown(self):
        self.tmp.cleanup()

    def runner(self, lookup, submit, **config):
        values = {
            "internal_url": "http://127.0.0.1:8182",
            "report_path": str(self.report_path),
        }
        values.update(config)
        return IngestRunner(RunnerConfig(**values), lookup_fn=lookup, submit_fn=submit)

    async def test_missing_episodes_are_submitted_with_typed_provenance(self):
        lookup = FakeLookup()
        submit = FakeSubmit()
        plan = Plan(source="sdlc", episodes=[episode()])
        report = await self.runner(lookup, submit).run([plan])
        self.assertEqual(len(lookup.calls), 1)
        self.assertEqual(lookup.calls[0][0], "owner--repo")
        self.assertEqual(len(submit.payloads), 1)
        payload = submit.payloads[0]
        self.assertEqual(payload["group"], "owner--repo")
        self.assertEqual(payload["kind"], "text")
        self.assertEqual(payload["origin"], "sdlc")
        self.assertEqual(payload["origin_ref"], "issue-1#design")
        self.assertEqual(payload["valid_at"], "2026-10-03T12:00:00Z")
        self.assertEqual(payload["tags"], ["sdlc"])
        self.assertEqual(payload["actor"], "ingest")
        self.assertEqual(report["totals"]["submitted"], 1)
        self.assertEqual(report["failures"], [])
        self.assertTrue(self.report_path.exists())

    async def test_existing_rows_are_not_submitted(self):
        active = episode(source_id="issue-1#active", content="active one")
        pending = episode(source_id="issue-2#pending", content="pending one")
        tombstoned = episode(source_id="issue-3#tomb", content="tomb one")
        failed = episode(source_id="issue-4#failed", content="failed one")
        statuses = {
            ("owner--repo", content_hash(normalize_content("active one"))): {
                "status": "active",
                "uuid": "u-active",
            },
            ("owner--repo", content_hash(normalize_content("pending one"))): {
                "status": "pending",
                "uuid": "u-pending",
            },
            ("owner--repo", content_hash(normalize_content("tomb one"))): {
                "status": "tombstoned",
                "uuid": "u-tomb",
            },
            ("owner--repo", content_hash(normalize_content("failed one"))): {
                "status": "failed",
                "uuid": "u-failed",
                "last_error": "absent",
            },
        }
        submit = FakeSubmit()
        report = await self.runner(FakeLookup(statuses), submit).run(
            [Plan(source="sdlc", episodes=[active, pending, tombstoned, failed])]
        )
        self.assertEqual(len(submit.payloads), 1)
        self.assertEqual(submit.payloads[0]["content"], "failed one")
        self.assertEqual(report["totals"]["active"], 1)
        self.assertEqual(report["totals"]["pending"], 1)
        self.assertEqual(report["totals"]["tombstoned"], 1)
        self.assertEqual(report["totals"]["submitted"], 1)

    async def test_lookup_is_batched_per_group(self):
        lookup = FakeLookup()
        submit = FakeSubmit()
        episodes = [
            episode(source_id=f"issue-{index}#body", content=f"content {index}") for index in range(3)
        ]
        episodes.append(episode(source_id="note:a#body", content="global content", group="global", source="notes"))
        await self.runner(lookup, submit).run([Plan(source="sdlc", episodes=episodes)])
        groups = [call[0] for call in lookup.calls]
        self.assertEqual(sorted(groups), ["global", "owner--repo"])
        self.assertEqual(len(submit.payloads), 4)

    async def test_duplicate_content_within_a_run_is_submitted_once(self):
        lookup = FakeLookup()
        submit = FakeSubmit()
        plan = Plan(source="sdlc", episodes=[episode(), episode(source_id="issue-2#body")])
        report = await self.runner(lookup, submit).run([plan])
        self.assertEqual(len(submit.payloads), 1)
        self.assertEqual(report["totals"]["deduplicated"], 1)

    async def test_a_lookup_failure_is_reported_and_not_submitted(self):
        report = await self.runner(FakeLookup(error="wrapper down"), FakeSubmit()).run(
            [Plan(source="sdlc", episodes=[episode()])]
        )
        self.assertEqual(report["totals"]["failed"], 1)
        self.assertEqual(report["failures"][0]["error"], "wrapper down")

    async def test_a_submit_failure_is_reported(self):
        report = await self.runner(FakeLookup(), FakeSubmit(error="refused")).run(
            [Plan(source="sdlc", episodes=[episode()])]
        )
        self.assertEqual(report["totals"]["failed"], 1)
        self.assertIn("refused", report["failures"][0]["error"])

    async def test_source_errors_are_included_without_stopping_the_run(self):
        report = await self.runner(FakeLookup(), FakeSubmit()).run(
            [Plan(source="notes", episodes=[episode(source="notes", source_id="note:a#body", content="note", group="global")])],
            source_errors={"docs": "gh is not installed"},
        )
        self.assertEqual(report["source_errors"], {"docs": "gh is not installed"})
        self.assertEqual(report["totals"]["submitted"], 1)
        self.assertEqual(report["failures"][0]["source"], "docs")
        self.assertEqual(report["failures"][0]["source_id"], "*")

    async def test_dry_run_makes_no_network_calls(self):
        lookup = FakeLookup()
        submit = FakeSubmit()
        report = await self.runner(lookup, submit, dry_run=True).run(
            [Plan(source="sdlc", episodes=[episode()])]
        )
        self.assertTrue(report["dry_run"])
        self.assertEqual(lookup.calls, [])
        self.assertEqual(submit.payloads, [])
        self.assertEqual(report["totals"]["built"], 1)

    async def test_the_report_is_written_and_never_read_back(self):
        lookup = FakeLookup()
        submit = FakeSubmit()
        await self.runner(lookup, submit).run([Plan(source="sdlc", episodes=[episode()])])
        first = json.loads(self.report_path.read_text())
        self.assertIn("timings", first)
        # A second run overwrites the report; nothing consults the old one.
        await self.runner(lookup, submit).run([Plan(source="sdlc", episodes=[episode(source_id="issue-9#body", content="other")])])
        second = json.loads(self.report_path.read_text())
        self.assertEqual(second["totals"]["built"], 1)
        self.assertEqual(len(submit.payloads), 2)

    async def test_empty_episodes_are_counted_and_skipped(self):
        report = await self.runner(FakeLookup(), FakeSubmit()).run(
            [Plan(source="notes", episodes=[episode(content="   ", source="notes", source_id="note:empty#body", group="global")])]
        )
        self.assertEqual(report["totals"]["empty"], 1)
        self.assertEqual(report["totals"]["submitted"], 0)


if __name__ == "__main__":
    unittest.main()
