import hashlib
import io
import json
import os
import sqlite3
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "modules/lib/photo-triage/src"))

from photo_triage.cli import main  # noqa: E402
from photo_triage.db import Database  # noqa: E402
from photo_triage.decisions import POLICY, POLICY_VERSION, decide_scan  # noqa: E402
from photo_triage.duplicates import HEURISTICS_VERSION  # noqa: E402
from photo_triage.score import PREVIEW_GENERATOR  # noqa: E402

UPDATED = "2024-01-01T00:00:00.000Z"


class DecisionTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.database = Database(Path(self._tmp.name, "triage.db"))
        self.scan_id = self.database.start_scan({})
        self.database.finish_scan(self.scan_id, "complete")

    def tearDown(self):
        self.database.close()
        self._tmp.cleanup()

    def add_asset(
        self,
        asset_id,
        *,
        width=1000,
        height=800,
        lap=200.0,
        mean=120.0,
        clip=0.0,
        phash=1,
        favorite=False,
        archived=False,
        trashed=False,
        visibility="timeline",
        verdict="keep",
        confidence=0.9,
        defects=(),
        preview_sha=None,
        checksum=None,
        updated_at=UPDATED,
        heuristics_version=HEURISTICS_VERSION,
        metrics=True,
        score=True,
        scan_state="scored",
        asset_type="IMAGE",
    ):
        preview = preview_sha or f"preview-{asset_id}"
        self.database.upsert_asset(
            {
                "id": asset_id,
                "type": asset_type,
                "width": width,
                "height": height,
                "isFavorite": favorite,
                "isArchived": archived,
                "isTrashed": trashed,
                "visibility": visibility,
                "checksum": checksum or f"checksum-{asset_id}",
                "localDateTime": UPDATED,
                "updatedAt": updated_at,
                "exifInfo": {"fileSizeInByte": width * height},
            }
        )
        self.database.add_scan_asset(self.scan_id, asset_id, scan_state, None)
        self.database.record_preview(
            asset_id,
            state="ready",
            reason=None,
            generator_id=PREVIEW_GENERATOR,
            bytes_sha256=preview,
            asset_checksum=checksum or f"checksum-{asset_id}",
            asset_updated_at=updated_at,
        )
        if metrics:
            self.database.update_preview_metrics(
                asset_id,
                phash=phash,
                lap_var=lap,
                mean_luma=mean,
                hi_clip=clip,
                heuristics_version=heuristics_version,
                bytes_sha256=preview,
            )
        if score:
            self.database.record_score(
                asset_id=asset_id,
                preview_sha256=preview,
                model_id="qwen",
                mmproj_sha256="projector",
                prompt_version="prompt",
                verdict=verdict,
                defects=list(defects),
                interest=3,
                confidence=confidence,
                raw_sha256="raw",
            )
        self.database.commit()

    def add_group(self, group_id, source, tier, members, distance=None):
        self.database.insert_duplicate_group(
            self.scan_id,
            group_id,
            source,
            tier,
            json.dumps(distance or {}),
            members,
        )
        self.database.commit()

    def mark_analysis(self, scan_id=None):
        scan_id = self.scan_id if scan_id is None else scan_id
        generation = self.database.start_analysis(
            scan_id,
            generator_id=PREVIEW_GENERATOR,
            heuristics_version=HEURISTICS_VERSION,
        )
        self.database.finish_analysis(scan_id, generation)

    def decide(self, **kwargs):
        self.mark_analysis()
        return decide_scan(self.database, self.scan_id, **kwargs)

    def populate(self):
        self.add_asset("exact-a", preview_sha="preview-exact", checksum="checksum-exact")
        self.add_asset("exact-b", preview_sha="preview-exact", checksum="checksum-exact")
        self.add_asset("near-c")
        self.add_asset(
            "near-d", verdict="delete", confidence=0.9, defects=("blur",), lap=10.0
        )
        self.add_asset(
            "general-e", verdict="delete", confidence=0.9, defects=("blur",), lap=10.0
        )
        self.add_asset("general-f", verdict="delete", confidence=0.9, lap=300.0)
        self.add_asset(
            "screenshot-g", verdict="delete", confidence=0.9, defects=("screenshot",)
        )
        self.add_asset("similar-h")
        self.add_asset("similar-i")
        self.add_group(
            "exact:1", "exact", "exact", [("exact-a", 0.0, 0), ("exact-b", 0.0, 1)]
        )
        self.add_group(
            "near:1", "near", "near", [("near-c", 0.0, 0), ("near-d", 2.0, 1)]
        )
        self.add_group(
            "immich:1",
            "immich",
            "similar",
            [("similar-h", None, 0), ("similar-i", None, 1)],
            {"suggestedKeepAssetIds": ["similar-h"]},
        )

    def decisions(self):
        return {
            row["asset_id"]: row["decision"]
            for row in self.database.decisions_for_scan(self.scan_id)
        }

    def reasons(self):
        return {
            row["asset_id"]: json.loads(row["signals_json"])["reason"]
            for row in self.database.decisions_for_scan(self.scan_id)
        }

    def test_stale_score_is_review(self):
        self.add_asset("stale", verdict="delete", confidence=0.9, defects=("blur",), lap=10.0)
        self.database.record_preview(
            "stale",
            state="ready",
            reason=None,
            generator_id=PREVIEW_GENERATOR,
            bytes_sha256="new-bytes",
            asset_checksum="checksum-stale",
            asset_updated_at=UPDATED,
        )
        self.database.commit()
        self.decide()
        self.assertEqual(self.decisions()["stale"], "review")
        self.assertEqual(self.reasons()["stale"], "missing_score")

    def test_missing_or_incomplete_analysis_blocks_decide(self):
        self.populate()
        with self.assertRaises(ValueError):
            decide_scan(self.database, self.scan_id)
        self.mark_analysis()
        self.database.connection.execute(
            "UPDATE scan_analysis SET groups_built = 0 WHERE scan_id = ?", (self.scan_id,)
        )
        self.database.commit()
        with self.assertRaises(ValueError):
            decide_scan(self.database, self.scan_id)

    def test_videos_are_not_decided(self):
        self.populate()
        self.add_asset("video", asset_type="VIDEO")
        result = self.decide()
        self.assertNotIn("video", result["assets"])
        self.assertNotIn("video", result["delete"] + result["review"] + result["keep"])
        self.assertEqual(result["counts"]["universe"], 9)

    def test_export_contract_reconciles(self):
        self.populate()
        export_path = Path(self._tmp.name, "membership.json")
        result = self.decide(export_path=export_path)
        export = json.loads(export_path.read_text())
        decided = set(export["delete"]) | set(export["review"]) | set(export["keep"])
        self.assertEqual(decided, set(export["assets"]))
        self.assertEqual(len(decided), export["counts"]["decided"])
        self.assertEqual(
            export["counts"]["decided"] + export["counts"]["undecided"],
            export["counts"]["universe"],
        )
        self.assertEqual(export["counts"]["universe"], export["counts"]["images"])
        self.assertTrue(export["safe_to_delete"])
        self.assertEqual(export["assets"]["exact-b"]["preview_sha256"], "preview-exact")
        self.assertEqual(export["assets"]["exact-b"]["asset_checksum"], "checksum-exact")
        self.assertEqual(export["run_id"], result["run_id"])
        run = self.database.connection.execute(
            "SELECT id, state, stats_json FROM runs WHERE id = ?", (export["run_id"],)
        ).fetchone()
        self.assertEqual(run["state"], "complete")
        stats = json.loads(run["stats_json"])
        self.assertEqual(
            stats["export_sha256"], hashlib.sha256(export_path.read_bytes()).hexdigest()
        )
        digest = export.pop("manifest_sha256")
        payload = json.dumps(export, sort_keys=True, separators=(",", ":")).encode("utf-8")
        self.assertEqual(digest, hashlib.sha256(payload).hexdigest())

    def test_decisions_follow_the_policy(self):
        self.populate()
        export_path = Path(self._tmp.name, "triage-membership.json")
        result = self.decide(export_path=export_path)
        self.assertEqual(
            self.decisions(),
            {
                "exact-a": "keep",
                "exact-b": "delete",
                "near-c": "keep",
                "near-d": "delete",
                "general-e": "delete",
                "general-f": "review",
                "screenshot-g": "review",
                "similar-h": "keep",
                "similar-i": "review",
            },
        )
        self.assertEqual(result["policy_version"], POLICY_VERSION)
        self.assertEqual(result["cap"], POLICY["delete_cap"])
        self.assertEqual(len(result["policy_fingerprint"]), 12)
        self.assertEqual(
            {key: result["counts"][key] for key in ("delete", "review", "keep", "capped")},
            {"delete": 3, "review": 3, "keep": 3, "capped": 0},
        )
        self.assertEqual(result["counts"]["decided"], 9)
        self.assertEqual(result["counts"]["universe"], 9)
        export = json.loads(export_path.read_text())
        self.assertEqual(export["delete"], ["exact-b", "general-e", "near-d"])
        self.assertEqual(export["keep"], ["exact-a", "near-c", "similar-h"])
        self.assertIn("similar-i", export["review"])
        self.assertEqual(export["assets"]["exact-b"]["reason"], "exact_duplicate")
        self.assertEqual(export["assets"]["exact-b"]["tier"], "exact")
        self.assertEqual(export["tiers"]["exact"]["delete"], 1)
        self.assertEqual(export["clusters"]["general"]["delete"], 1)

    def test_decide_requires_a_completed_analysis(self):
        self.populate()
        with self.assertRaises(ValueError):
            decide_scan(self.database, self.scan_id)
        self.mark_analysis()
        self.assertEqual(decide_scan(self.database, self.scan_id)["counts"]["delete"], 3)

    def test_cap_demotes_the_tail_to_review(self):
        self.populate()
        export_path = Path(self._tmp.name, "membership.json")
        result = self.decide(cap=1, export_path=export_path)
        self.assertEqual(result["counts"]["delete"], 1)
        self.assertEqual(result["counts"]["capped"], 2)
        decisions = self.decisions()
        self.assertEqual(decisions["exact-b"], "delete")
        self.assertEqual(decisions["near-d"], "review")
        self.assertEqual(decisions["general-e"], "review")
        signals = {
            row["asset_id"]: json.loads(row["signals_json"])
            for row in self.database.decisions_for_scan(self.scan_id)
        }
        self.assertEqual(signals["near-d"]["reason"], "cap")
        self.assertEqual(signals["near-d"]["original_reason"], "near_duplicate")
        self.assertTrue(signals["near-d"]["suppressed_by_cap"])
        export = json.loads(export_path.read_text())
        self.assertTrue(export["assets"]["near-d"]["suppressed_by_cap"])
        self.assertEqual(export["assets"]["near-d"]["original_reason"], "near_duplicate")

    def test_fingerprint_covers_the_cap(self):
        self.populate()
        first = self.decide(cap=1)["policy_fingerprint"]
        second = self.decide(cap=2)["policy_fingerprint"]
        self.assertNotEqual(first, second)

    def test_cap_zero_is_allowed(self):
        self.populate()
        result = self.decide(cap=0)
        self.assertEqual(result["counts"]["delete"], 0)
        self.assertEqual(result["counts"]["capped"], 3)

    def test_cap_outside_the_policy_is_rejected(self):
        self.populate()
        self.mark_analysis()
        for cap in (-1, POLICY["delete_cap"] + 1):
            with self.assertRaises(ValueError):
                decide_scan(self.database, self.scan_id, cap=cap)

    def test_unscored_keeper_blocks_group_deletes(self):
        self.add_asset("keeper", score=False, scan_state="pending", preview_sha="shared")
        self.add_asset("copy", preview_sha="shared")
        self.add_group("exact:1", "exact", "exact", [("keeper", 0.0, 0), ("copy", 0.0, 1)])
        self.decide()
        self.assertEqual(self.decisions(), {"copy": "review"})
        self.assertEqual(self.reasons()["copy"], "keeper_unscored")

    def test_untrusted_keeper_blocks_near_deletes(self):
        self.add_asset("keeper", verdict="review")
        self.add_asset(
            "copy", verdict="delete", confidence=0.9, defects=("blur",), lap=10.0
        )
        self.add_group("near:1", "near", "near", [("keeper", 2.0, 0), ("copy", 2.0, 1)])
        self.decide()
        self.assertEqual(self.decisions(), {"keeper": "keep", "copy": "review"})
        self.assertEqual(self.reasons()["copy"], "keeper_untrusted")

    def test_review_only_keeper_blocks_near_deletes(self):
        self.add_asset("keeper", defects=("screenshot",))
        self.add_asset(
            "copy", verdict="delete", confidence=0.9, defects=("blur",), lap=10.0
        )
        self.add_group("near:1", "near", "near", [("keeper", 2.0, 0), ("copy", 2.0, 1)])
        self.decide()
        self.assertEqual(self.reasons()["copy"], "keeper_review_only")

    def test_protected_keeper_blocks_near_deletes(self):
        self.add_asset("keeper", trashed=True)
        self.add_asset(
            "copy", verdict="delete", confidence=0.9, defects=("blur",), lap=10.0
        )
        self.add_group("near:1", "near", "near", [("keeper", 2.0, 0), ("copy", 2.0, 1)])
        self.decide()
        self.assertEqual(self.reasons()["copy"], "keeper_protected")

    def test_near_delete_requires_keeper_within_threshold(self):
        self.add_asset("keeper", phash=0)
        self.add_asset(
            "copy", phash=0b1111111111111111, verdict="delete", confidence=0.9, defects=("blur",), lap=10.0
        )
        self.add_group("near:1", "near", "near", [("keeper", 0.0, 0), ("copy", 16.0, 1)])
        self.decide()
        self.assertEqual(self.reasons()["copy"], "near_distance")

    def test_exact_group_requires_matching_checksum(self):
        self.add_asset("keeper", preview_sha="one", checksum="first")
        self.add_asset("copy", preview_sha="one", checksum="second")
        self.add_group("exact:1", "exact", "exact", [("keeper", 0.0, 0), ("copy", 0.0, 1)])
        self.decide()
        self.assertEqual(self.reasons()["copy"], "exact_checksum_mismatch")

    def test_exact_group_requires_matching_preview(self):
        self.add_asset("keeper", preview_sha="one", checksum="shared")
        self.add_asset("copy", preview_sha="two", checksum="shared")
        self.add_group("exact:1", "exact", "exact", [("keeper", 0.0, 0), ("copy", 0.0, 1)])
        self.decide()
        self.assertEqual(self.reasons()["copy"], "exact_preview_mismatch")

    def test_keeper_of_another_group_is_never_deleted(self):
        self.add_asset(
            "exact-keeper", preview_sha="shared", checksum="checksum-exact"
        )
        self.add_asset("shared-copy", preview_sha="shared", checksum="checksum-exact")
        self.add_asset(
            "near-copy", verdict="delete", confidence=0.9, defects=("blur",), lap=10.0
        )
        self.add_group(
            "exact:1",
            "exact",
            "exact",
            [("exact-keeper", 0.0, 0), ("shared-copy", 0.0, 1)],
        )
        self.add_group(
            "near:1",
            "near",
            "near",
            [("shared-copy", 2.0, 0), ("near-copy", 2.0, 1)],
        )
        self.decide()
        decisions = self.decisions()
        self.assertEqual(decisions["shared-copy"], "keep")
        self.assertEqual(self.reasons()["shared-copy"], "near_keep")
        self.assertEqual(decisions["near-copy"], "delete")

    def test_review_only_defects_survive_groups(self):
        self.add_asset("keeper")
        self.add_asset(
            "screenshot", verdict="delete", confidence=0.9, defects=("screenshot",)
        )
        self.add_group(
            "near:1", "near", "near", [("keeper", 2.0, 0), ("screenshot", 2.0, 1)]
        )
        self.decide()
        self.assertEqual(self.decisions()["screenshot"], "review")
        self.assertEqual(self.reasons()["screenshot"], "screenshot")

    def test_protected_assets_are_kept(self):
        self.add_asset("keeper", preview_sha="shared", checksum="checksum-exact")
        self.add_asset(
            "favorite", favorite=True, preview_sha="shared", checksum="checksum-exact"
        )
        self.add_asset(
            "archived", archived=True, preview_sha="shared", checksum="checksum-exact"
        )
        self.add_asset(
            "hidden", visibility="hidden", preview_sha="shared", checksum="checksum-exact"
        )
        self.add_asset(
            "trashed", trashed=True, preview_sha="shared", checksum="checksum-exact"
        )
        self.add_group(
            "exact:1",
            "exact",
            "exact",
            [
                ("keeper", 0.0, 0),
                ("favorite", 0.0, 1),
                ("archived", 0.0, 2),
                ("hidden", 0.0, 3),
                ("trashed", 0.0, 4),
            ],
        )
        self.decide()
        decisions = self.decisions()
        reasons = self.reasons()
        for asset_id in ("favorite", "archived", "hidden", "trashed"):
            self.assertEqual(decisions[asset_id], "keep")
        self.assertEqual(reasons["favorite"], "protected_favorite")
        self.assertEqual(reasons["archived"], "protected_archived")
        self.assertEqual(reasons["hidden"], "protected_visibility")
        self.assertEqual(reasons["trashed"], "protected_trashed")

    def test_null_keep_rank_is_review(self):
        self.add_asset("keeper", preview_sha="shared", checksum="checksum-exact")
        self.add_asset("copy", preview_sha="shared", checksum="checksum-exact")
        self.add_group(
            "exact:1", "exact", "exact", [("keeper", 0.0, 0), ("copy", 0.0, None)]
        )
        self.decide()
        self.assertEqual(self.decisions()["copy"], "review")
        self.assertEqual(self.reasons()["copy"], "unranked")

    def test_missing_metrics_are_review(self):
        self.add_asset("keeper", preview_sha="shared", checksum="checksum-exact")
        self.add_asset(
            "copy", preview_sha="shared", checksum="checksum-exact", metrics=False
        )
        self.add_group("exact:1", "exact", "exact", [("keeper", 0.0, 0), ("copy", 0.0, 1)])
        self.decide()
        self.assertEqual(self.decisions()["copy"], "review")
        self.assertEqual(self.reasons()["copy"], "missing_metrics")

    def test_stale_heuristics_are_review(self):
        self.add_asset(
            "stale",
            verdict="delete",
            confidence=0.9,
            defects=("blur",),
            lap=10.0,
            heuristics_version="v0",
        )
        self.decide()
        self.assertEqual(self.decisions()["stale"], "review")
        self.assertEqual(self.reasons()["stale"], "stale_heuristics")

    def test_changed_asset_preview_is_stale(self):
        self.add_asset("changed", verdict="delete", confidence=0.9, defects=("blur",), lap=10.0)
        self.database.connection.execute(
            "UPDATE assets SET updated_at = '2025-01-01T00:00:00.000Z' WHERE id = 'changed'"
        )
        self.database.commit()
        self.decide()
        self.assertEqual(self.reasons()["changed"], "stale_preview")

    def test_metrics_after_analysis_cutoff_are_stale(self):
        self.mark_analysis()
        self.add_asset("late", verdict="delete", confidence=0.9, defects=("blur",), lap=10.0)
        self.database.connection.execute(
            "UPDATE scan_analysis SET completed_at = '2000-01-01T00:00:00.000Z'"
        )
        self.database.commit()
        decide_scan(self.database, self.scan_id)
        self.assertEqual(self.reasons()["late"], "stale_analysis")

    def test_scored_asset_without_an_active_score_is_review(self):
        self.add_asset("orphan", score=False)
        self.decide()
        self.assertEqual(self.decisions()["orphan"], "review")
        self.assertEqual(self.reasons()["orphan"], "missing_score")

    def test_multiple_active_scores_use_the_latest(self):
        self.add_asset("dup", lap=10.0, phash=1)
        self.database.connection.execute(
            "INSERT INTO scores(asset_id, preview_sha256, model_id, mmproj_sha256, "
            "prompt_version, verdict, defects_json, interest, confidence, raw_sha256, "
            "created_at, is_active) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)",
            (
                "dup",
                "preview-dup",
                "qwen2",
                "projector",
                "prompt",
                "delete",
                '["blur"]',
                3,
                0.99,
                "raw",
                "2024-02-01T00:00:00Z",
            ),
        )
        self.database.commit()
        self.decide()
        self.assertEqual(self.decisions(), {"dup": "delete"})

    def test_partial_scan_requires_opt_in_and_never_allows_failed(self):
        partial = self.database.start_scan({})
        self.database.finish_scan(partial, "partial")
        self.mark_analysis(partial)
        with self.assertRaises(ValueError):
            decide_scan(self.database, partial)
        self.assertEqual(
            decide_scan(self.database, partial, allow_partial=True)["scan_state"],
            "partial",
        )
        failed = self.database.start_scan({})
        self.database.finish_scan(failed, "failed")
        self.mark_analysis(failed)
        with self.assertRaises(ValueError):
            decide_scan(self.database, failed, allow_partial=True)

    def test_latest_complete_scan_ignores_partial(self):
        partial = self.database.start_scan({})
        self.database.finish_scan(partial, "partial")
        self.assertEqual(self.database.latest_complete_scan(), self.scan_id)

    def test_coverage_states_are_not_rewritten(self):
        self.populate()
        self.decide()
        coverage = self.database.coverage(self.scan_id)
        self.assertNotIn("decided", coverage["states"])
        self.assertEqual(coverage["states"]["scored"], 9)

    def test_decisions_are_idempotent(self):
        self.populate()
        first = self.decide()
        second = self.decide()
        self.assertEqual(first["counts"], second["counts"])
        self.assertEqual(len(self.database.decisions_for_scan(self.scan_id)), 9)

    def test_policy_version_matches_the_database(self):
        self.populate()
        result = self.decide()
        versions = {
            row["policy_version"]
            for row in self.database.connection.execute(
                "SELECT policy_version FROM decisions WHERE scan_id = ?", (self.scan_id,)
            )
        }
        self.assertEqual(versions, {POLICY_VERSION})
        self.assertNotEqual(result["policy_fingerprint"], POLICY_VERSION)

    def test_run_row_is_recorded(self):
        self.populate()
        self.decide(export_path=Path(self._tmp.name, "membership.json"))
        row = self.database.connection.execute(
            "SELECT kind, scan_id, state, stats_json FROM runs WHERE kind = 'decide'"
        ).fetchone()
        self.assertEqual(
            (row["kind"], row["scan_id"], row["state"]),
            ("decide", self.scan_id, "complete"),
        )
        stats = json.loads(row["stats_json"])
        self.assertEqual(stats["cap"], POLICY["delete_cap"])
        self.assertEqual(stats["policy_version"], POLICY_VERSION)
        self.assertEqual(len(stats["export_sha256"]), 64)
        self.assertIsNotNone(stats["export_path"])

    def test_previous_running_run_is_marked_interrupted(self):
        first = self.database.start_run("decide", self.scan_id)
        self.database.start_run("decide", self.scan_id)
        state = self.database.connection.execute(
            "SELECT state FROM runs WHERE id = ?", (first,)
        ).fetchone()["state"]
        self.assertEqual(state, "interrupted")

    def test_dry_run_persists_nothing(self):
        self.populate()
        export_path = Path(self._tmp.name, "triage-membership.json")
        result = self.decide(export_path=export_path, dry_run=True)
        self.assertTrue(result["dry_run"])
        self.assertEqual(result["counts"]["delete"], 3)
        self.assertEqual(self.database.decisions_for_scan(self.scan_id), [])
        self.assertFalse(export_path.exists())
        runs = self.database.connection.execute(
            "SELECT count(*) AS count FROM runs WHERE kind = 'decide'"
        ).fetchone()["count"]
        self.assertEqual(runs, 0)

    def test_export_is_written_atomically(self):
        self.populate()
        export_path = Path(self._tmp.name, "triage-membership.json")
        self.decide(export_path=export_path)
        self.assertEqual(list(Path(self._tmp.name).glob(".triage-membership*")), [])
        export = json.loads(export_path.read_text())
        self.assertEqual(export["scan_id"], self.scan_id)
        self.assertEqual(export["assets"]["general-e"]["model_verdict"], "delete")
        self.assertEqual(export["counts"]["undecided"], 0)

    def test_failed_export_marks_the_run_failed(self):
        self.populate()
        with self.assertRaises(OSError):
            self.decide(export_path=Path(self._tmp.name))
        state = self.database.connection.execute(
            "SELECT state FROM runs WHERE kind = 'decide' ORDER BY id DESC LIMIT 1"
        ).fetchone()["state"]
        self.assertEqual(state, "failed")

    def test_schema_v4_decisions_are_migrated_to_a_primary_key(self):
        path = Path(self._tmp.name, "v4.db")
        raw = sqlite3.connect(path)
        raw.executescript(
            """
            CREATE TABLE schema_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            INSERT INTO schema_meta(key, value) VALUES ('schema_version', '4');
            CREATE TABLE decisions (
                asset_id TEXT NOT NULL,
                scan_id INTEGER NOT NULL,
                policy_version TEXT NOT NULL,
                heuristics_version TEXT NOT NULL,
                score_id INTEGER,
                cluster TEXT,
                signals_json TEXT NOT NULL,
                decision TEXT NOT NULL,
                decided_at TEXT NOT NULL
            );
            INSERT INTO decisions VALUES (
                'asset', 7, 'policy', 'v1', NULL, 'blur', '{}', 'review', '2024-01-01T00:00:00Z'
            );
            """
        )
        raw.commit()
        raw.close()
        database = Database(path)
        try:
            keys = [
                row["name"]
                for row in database.connection.execute("PRAGMA table_info(decisions)")
                if row["pk"] > 0
            ]
            self.assertEqual(keys, ["asset_id", "scan_id"])
            self.assertEqual(
                database.connection.execute(
                    "SELECT value FROM schema_meta WHERE key = 'schema_version'"
                ).fetchone()["value"],
                "8",
            )
            self.assertIn("metrics_sha256", database._columns("previews"))
            self.assertEqual(
                database.connection.execute(
                    "SELECT count(*) AS count FROM scan_analysis"
                ).fetchone()["count"],
                0,
            )
            row = database.connection.execute(
                "SELECT asset_id, scan_id, decision FROM decisions"
            ).fetchone()
            self.assertEqual(tuple(row), ("asset", 7, "review"))
        finally:
            database.close()

    def test_cli_decide_writes_the_membership_file(self):
        self.populate()
        self.mark_analysis()
        keys = ("PHOTO_TRIAGE_DATA_DIR",)
        old = {key: os.environ.get(key) for key in keys}
        os.environ["PHOTO_TRIAGE_DATA_DIR"] = self._tmp.name
        try:
            with redirect_stdout(io.StringIO()) as out:
                self.assertEqual(main(["decide"]), 0)
            summary = json.loads(out.getvalue())
            self.assertEqual(summary["counts"]["delete"], 3)
            self.assertNotIn("assets", summary)
            path = Path(self._tmp.name, f"triage-membership-{self.scan_id}.json")
            self.assertEqual(summary["export"], str(path))
            self.assertTrue(path.is_file())
            self.assertEqual(main(["decide", "--dry-run"]), 0)
        finally:
            for key, value in old.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value

    def test_cli_rejects_an_out_of_range_cap(self):
        self.populate()
        self.mark_analysis()
        keys = ("PHOTO_TRIAGE_DATA_DIR",)
        old = {key: os.environ.get(key) for key in keys}
        os.environ["PHOTO_TRIAGE_DATA_DIR"] = self._tmp.name
        try:
            self.assertEqual(main(["decide", "--cap", str(POLICY["delete_cap"] + 1)]), 2)
            self.assertEqual(main(["decide", "--cap", "-1"]), 2)
        finally:
            for key, value in old.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value


if __name__ == "__main__":
    unittest.main()
