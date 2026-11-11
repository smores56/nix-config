import io
import json
import os
import sqlite3
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
sys.path.insert(0, str(Path(__file__).parents[1] / "modules/lib/photo-triage/src"))

from fake_immich import FakeImmich  # noqa: E402
from photo_triage import calibration  # noqa: E402
from photo_triage.cli import main  # noqa: E402
from photo_triage.db import Database  # noqa: E402
from photo_triage.immich import ALBUM_PERMISSIONS, ImmichClient  # noqa: E402


class CalibrationTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.database = Database(Path(self._tmp.name, "triage.db"))
        self.scan_id = self.database.start_scan({})
        self.database.finish_scan(self.scan_id, "complete")

    def tearDown(self):
        self.database.close()
        self._tmp.cleanup()

    def decide(self, asset_id, cluster, decision, tier=None):
        self.database.insert_decision(
            asset_id=asset_id,
            scan_id=self.scan_id,
            policy_version="policy",
            heuristics_version="v1",
            score_id=None,
            cluster=cluster,
            signals={"tier": tier, "reason": decision},
            decision=decision,
        )
        self.database.commit()

    def test_wilson_bounds(self):
        low, high = calibration.wilson(0, 10)
        self.assertEqual(low, 0.0)
        self.assertAlmostEqual(high, 0.2775, places=3)
        low, high = calibration.wilson(10, 10)
        self.assertAlmostEqual(low, 0.7225, places=3)
        self.assertEqual(high, 1.0)
        self.assertEqual(calibration.wilson(0, 0), (0.0, 0.0))

    def test_sample_is_stratified_and_deterministic(self):
        decisions = []
        for cluster in ("blur", "dark", "general", "screenshot", "document", "bright", "low_res"):
            for index in range(50):
                decisions.append(
                    {
                        "asset_id": f"{cluster}-{index:02d}",
                        "cluster": cluster,
                        "decision": "review",
                    }
                )
        sample = calibration.build_sample(decisions, min_per_cluster=30, total=300)
        self.assertEqual(len(sample), 300)
        counts = {}
        for item in sample:
            counts[item["cluster"]] = counts.get(item["cluster"], 0) + 1
        self.assertTrue(all(count >= 30 for count in counts.values()))
        again = calibration.build_sample(decisions, min_per_cluster=30, total=300)
        self.assertEqual(
            [item["asset_id"] for item in sample],
            [item["asset_id"] for item in again],
        )

    def test_sample_prefers_a_delete_member_over_the_keeper(self):
        ids = sorted((f"asset-{index}" for index in range(20)), key=calibration._digest)
        keeper, member = ids[0], ids[1]
        decisions = [
            {"asset_id": keeper, "cluster": "near", "decision": "keep", "groups": ["g1"]},
            {"asset_id": member, "cluster": "near", "decision": "delete", "groups": ["g1"]},
        ]
        sample = calibration.build_sample(decisions, min_per_cluster=1, total=10)
        self.assertEqual([item["asset_id"] for item in sample], [member])

    def test_split_is_per_cluster_and_deterministic(self):
        sample = [
            {"asset_id": f"{cluster}-{index:02d}", "cluster": cluster}
            for cluster in ("blur", "general")
            for index in range(10)
        ]
        split = calibration.split_sample(sample)
        self.assertEqual(len(split["dev"]) + len(split["heldout"]), 20)
        self.assertEqual(len(split["dev"]), 8)
        for cluster in ("blur", "general"):
            self.assertTrue(
                any(item["cluster"] == cluster for item in split["heldout"])
            )
        self.assertEqual(split, calibration.split_sample(sample))

    def test_label_report_counts_false_deletes(self):
        decisions = [
            {"asset_id": "d1", "cluster": "general", "decision": "delete"},
            {"asset_id": "d2", "cluster": "blur", "decision": "delete"},
            {"asset_id": "r1", "cluster": "general", "decision": "review"},
            {"asset_id": "k1", "cluster": "general", "decision": "keep"},
        ]
        labels = {"d1": "keep", "d2": "delete"}
        report = calibration.label_report(decisions, labels, ["d1", "d2", "r1", "k1"])
        self.assertEqual(report["delete_candidates"], 2)
        self.assertEqual(report["overall"]["labelled"], 2)
        self.assertEqual(report["overall"]["false_deletes"], 1)
        self.assertEqual(report["overall"]["true_deletes"], 1)
        self.assertAlmostEqual(report["overall"]["precision"], 0.5)
        self.assertIn("blur", report["clusters"])

    def test_go_no_go_rules(self):
        false_report = {
            "overall": {
                "labelled": 2,
                "false_deletes": 1,
                "false_rate": 0.5,
                "false_rate_wilson": [0.09, 0.91],
            }
        }
        self.assertFalse(calibration.go_no_go(false_report, min_labelled=1)["passed"])
        self.assertTrue(
            calibration.go_no_go(
                false_report, max_false_rate=0.95, min_labelled=1
            )["passed"]
        )
        clean = {
            "overall": {
                "labelled": 2,
                "false_deletes": 0,
                "false_rate": 0.0,
                "false_rate_wilson": [0.0, 0.66],
            }
        }
        self.assertTrue(calibration.go_no_go(clean, min_labelled=1)["passed"])
        empty = {
            "overall": {
                "labelled": 0,
                "false_deletes": 0,
                "false_rate": 0.0,
                "false_rate_wilson": [0.0, 0.0],
            }
        }
        self.assertFalse(calibration.go_no_go(empty, min_labelled=1)["passed"])
        self.assertFalse(calibration.go_no_go(clean, min_labelled=3)["passed"])

    def test_sample_and_labels_round_trip(self):
        split = {
            "dev": [{"asset_id": "a", "cluster": "general"}],
            "heldout": [{"asset_id": "b", "cluster": "general"}],
        }
        calibration.record_sample(self.database, "scan-1", self.scan_id, split)
        rows = {row["asset_id"]: row["split"] for row in self.database.sample_assets("scan-1")}
        self.assertEqual(rows, {"a": "dev", "b": "heldout"})
        entries = [("a", "keep"), ("b", "delete")]
        self.decide("a", "general", "delete")
        self.decide("b", "general", "delete")
        decisions = calibration.decisions_for_scan(self.database, self.scan_id)
        self.assertEqual(
            calibration.record_labels(self.database, decisions, entries), 2
        )
        labels = {
            row["asset_id"]: row["label"]
            for row in self.database.labels_for(["a", "b"])
        }
        self.assertEqual(labels, {"a": "keep", "b": "delete"})

    def test_publish_sample_albums(self):
        assets = [{"id": f"asset-{index}"} for index in range(4)]
        socket = str(Path(self._tmp.name, "immich.sock"))
        fake = FakeImmich(
            assets=assets,
            keys={"album-key": sorted(ALBUM_PERMISSIONS)},
            api_key="album-key",
            unix_path=socket,
        )
        fake.start()
        try:
            client = ImmichClient(socket_path=socket, api_key="album-key")
            run_id = self.database.start_run("decide", self.scan_id)
            self.database.finish_run(
                run_id, "complete", {"policy_fingerprint": "policy"}
            )
            split = {
                "dev": [{"asset_id": "asset-0"}, {"asset_id": "asset-1"}],
                "heldout": [{"asset_id": "asset-2"}],
            }
            reports = calibration.publish_sample(
                self.database, client, self.scan_id, split
            )
            self.assertTrue(all(report.reconciled for report in reports))
            dev_id = self.database.album("calibration-dev")["immich_album_id"]
            heldout_id = self.database.album("calibration-heldout")["immich_album_id"]
            self.assertEqual(
                sorted(fake.album_asset_ids(dev_id)), ["asset-0", "asset-1"]
            )
            self.assertEqual(fake.album_asset_ids(heldout_id), ["asset-2"])
        finally:
            fake.stop()

    def test_cli_sample_labels_report(self):
        for index in range(40):
            self.decide(f"asset-{index}", "general", "delete")
        self.decide("asset-review", "general", "review")
        run_id = self.database.start_run("decide", self.scan_id)
        self.database.finish_run(
            run_id,
            "complete",
            {
                "policy_version": "policy",
                "policy_fingerprint": "policy",
                "heuristics_version": "v1",
            },
        )
        old = os.environ.get("PHOTO_TRIAGE_DATA_DIR")
        os.environ["PHOTO_TRIAGE_DATA_DIR"] = self._tmp.name
        labels_path = Path(self._tmp.name, "labels.json")
        labels_path.write_text(
            json.dumps({f"asset-{index}": "delete" for index in range(40)})
        )
        try:
            with redirect_stdout(io.StringIO()) as out:
                self.assertEqual(
                    main(
                        [
                            "calibration",
                            "sample",
                            "--min-per-cluster",
                            "40",
                            "--total",
                            "40",
                        ]
                    ),
                    0,
                )
            self.assertEqual(json.loads(out.getvalue())["sample"], 40)
            with redirect_stdout(io.StringIO()) as out:
                self.assertEqual(
                    main(["calibration", "labels", "--file", str(labels_path)]), 0
                )
            self.assertEqual(json.loads(out.getvalue())["labels"], 40)
            with redirect_stdout(io.StringIO()) as out:
                self.assertEqual(
                    main(
                        [
                            "calibration",
                            "report",
                            "--min-labelled",
                            "10",
                        ]
                    ),
                    0,
                )
            report = json.loads(out.getvalue())
            self.assertEqual(report["heldout"]["overall"]["false_deletes"], 0)
            self.assertTrue(report["go_no_go"]["passed"])
            self.assertEqual(report["decide_run_id"], run_id)
        finally:
            if old is None:
                os.environ.pop("PHOTO_TRIAGE_DATA_DIR", None)
            else:
                os.environ["PHOTO_TRIAGE_DATA_DIR"] = old

    def test_schema_v6_migrates_calibration_samples(self):
        path = Path(self._tmp.name, "v6.db")
        raw = sqlite3.connect(path)
        raw.executescript(
            """
            CREATE TABLE schema_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            INSERT INTO schema_meta(key, value) VALUES ('schema_version', '6');
            """
        )
        raw.commit()
        raw.close()
        database = Database(path)
        try:
            self.assertEqual(
                database.connection.execute(
                    "SELECT value FROM schema_meta WHERE key = 'schema_version'"
                ).fetchone()["value"],
                "9",
            )
            database.record_sample("scan-1", self.scan_id, [("asset", "dev")])
            self.assertEqual(len(database.sample_assets("scan-1")), 1)
        finally:
            database.close()


if __name__ == "__main__":
    unittest.main()
