import hashlib
import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
sys.path.insert(0, str(Path(__file__).parents[1] / "modules/lib/photo-triage/src"))

from fake_immich import FakeImmich  # noqa: E402
from photo_triage.albums import (  # noqa: E402
    ALBUM_NAMES,
    AlbumError,
    album_status,
    load_export,
    manifest_digest,
    preflight,
    sync_export,
)
from photo_triage.cli import main  # noqa: E402
from photo_triage.db import Database  # noqa: E402
from photo_triage.immich import (  # noqa: E402
    ALBUM_PERMISSIONS,
    ImmichClient,
    ImmichPermissionError,
)


class AlbumTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.database = Database(Path(self._tmp.name, "triage.db"))
        self.scan_id = self.database.start_scan({})
        self.database.finish_scan(self.scan_id, "complete")
        self.socket = str(Path(self._tmp.name, "immich.sock"))
        self.fake = FakeImmich(
            assets=[{"id": asset_id} for asset_id in ("d1", "r1", "k1", "p1")],
            keys={"album-key": sorted(ALBUM_PERMISSIONS)},
            api_key="album-key",
            unix_path=self.socket,
        )
        self.fake.start()
        self.client = ImmichClient(socket_path=self.socket, api_key="album-key")

    def tearDown(self):
        self.fake.stop()
        self.database.close()
        self._tmp.cleanup()

    def export(
        self,
        *,
        delete=("d1",),
        review=("r1",),
        keep=("k1",),
        safe=True,
        run_state="complete",
        calibration=True,
    ):
        assets = {}
        for asset_id in delete:
            assets[asset_id] = {"decision": "delete"}
        for asset_id in review:
            assets[asset_id] = {"decision": "review"}
        for asset_id in keep:
            assets[asset_id] = {"decision": "keep"}
        run_id = self.database.start_run("decide", self.scan_id)
        export = {
            "scan_id": self.scan_id,
            "scan_state": "complete",
            "run_id": run_id,
            "policy_version": "policy",
            "policy_fingerprint": "fingerprint",
            "heuristics_version": "v1",
            "generator_id": "generator",
            "analysis_generation": 1,
            "cap": 100,
            "delete": sorted(delete),
            "review": sorted(review),
            "keep": sorted(keep),
            "undecided": [],
            "assets": assets,
            "counts": {
                "delete": len(delete),
                "review": len(review),
                "keep": len(keep),
                "capped": 0,
                "decided": len(assets),
                "undecided": 0,
                "universe": len(assets),
            },
            "safe_to_delete": safe,
        }
        export["manifest_sha256"] = manifest_digest(export)
        path = Path(self._tmp.name, f"membership-{run_id}.json")
        body = json.dumps(export, indent=2, sort_keys=True) + "\n"
        path.write_text(body)
        self.database.finish_run(
            run_id,
            run_state,
            {
                "policy_version": "policy",
                "policy_fingerprint": "fingerprint",
                "heuristics_version": "v1",
                "generator_id": "generator",
                "analysis_generation": 1,
                "cap": 100,
                "export_sha256": hashlib.sha256(body.encode()).hexdigest(),
            },
        )
        if calibration:
            report_run = self.database.start_run("calibration-report", self.scan_id)
            self.database.finish_run(
                report_run,
                "complete",
                {
                    "decide_run_id": run_id,
                    "policy_fingerprint": "fingerprint",
                    "go_no_go": {"passed": True},
                },
            )
        return export, path

    def test_album_sync_requires_a_passing_calibration_report(self):
        export, path = self.export(calibration=False)
        with self.assertRaises(AlbumError):
            load_export(self.database, path)
        report_run = self.database.start_run("calibration-report", self.scan_id)
        self.database.finish_run(
            report_run,
            "failed",
            {
                "decide_run_id": export["run_id"],
                "policy_fingerprint": "fingerprint",
                "go_no_go": {"passed": False},
            },
        )
        with self.assertRaises(AlbumError):
            load_export(self.database, path)

    def test_verify_accepts_a_matching_artifact(self):
        export, path = self.export()
        loaded = load_export(self.database, path)
        self.assertEqual(loaded["run_id"], export["run_id"])

    def test_verify_rejects_tampering_and_stale_files(self):
        export, path = self.export()
        tampered = json.loads(path.read_text())
        tampered["delete"] = ["k1"]
        path.write_text(json.dumps(tampered))
        with self.assertRaises(AlbumError):
            load_export(self.database, path)

        export, path = self.export()
        path.write_text(path.read_text() + " ")
        with self.assertRaises(AlbumError):
            load_export(self.database, path)

    def test_verify_rejects_unsafe_and_incomplete_runs(self):
        export, path = self.export(safe=False)
        with self.assertRaises(AlbumError):
            load_export(self.database, path)
        export, path = self.export(run_state="failed")
        with self.assertRaises(AlbumError):
            load_export(self.database, path)

    def test_dry_run_calls_nothing(self):
        self.database.set_album("delete", "old", None)
        self.database.replace_album_members("delete", ["r1"], 0)
        export, path = self.export()
        reports = sync_export(
            self.database, None, export, path=path, dry_run=True
        )
        self.assertEqual(reports[0].add, ("d1",))
        self.assertEqual(reports[0].remove, ("r1",))
        self.assertEqual(self.fake.requests, [])

    def test_verify_rejects_a_superseded_export(self):
        old_export, old_path = self.export()
        self.export()
        with self.assertRaises(AlbumError):
            load_export(self.database, old_path)

    def test_verify_rejects_a_superseded_scan(self):
        export, path = self.export()
        newer = self.database.start_scan({})
        self.database.finish_scan(newer, "complete")
        with self.assertRaises(AlbumError):
            load_export(self.database, path)

    def test_transient_error_is_retried(self):
        self.fake.queue_failure(502, count=1, method="PUT", path_prefix="/api/albums/")
        export, path = self.export()
        reports = sync_export(
            self.database,
            self.client,
            export,
            path=path,
            sleep=lambda _: None,
        )
        self.assertTrue(all(report.reconciled for report in reports))
        delete_id = self.database.album("delete")["immich_album_id"]
        self.assertEqual(self.fake.album_asset_ids(delete_id), ["d1"])

    def test_live_sync_creates_both_albums_and_persists_snapshot(self):
        export, path = self.export()
        reports = sync_export(
            self.database, self.client, export, path=path, reconcile=True
        )
        self.assertTrue(all(report.created for report in reports))
        self.assertTrue(all(report.reconciled for report in reports))
        delete_id = self.database.album("delete")["immich_album_id"]
        review_id = self.database.album("review")["immich_album_id"]
        self.assertEqual(self.fake.album_asset_ids(delete_id), ["d1"])
        self.assertEqual(self.fake.album_asset_ids(review_id), ["r1"])
        self.assertEqual(self.database.album_members("delete"), ["d1"])
        asset_requests = [
            (request.method, request.path)
            for request in self.fake.requests
            if request.path.endswith("/assets")
        ]
        self.assertEqual(asset_requests, [("PUT", f"/api/albums/{delete_id}/assets"),
                                          ("PUT", f"/api/albums/{review_id}/assets")])

    def test_second_sync_is_idempotent(self):
        export, path = self.export()
        sync_export(self.database, self.client, export, path=path)
        before = len(self.fake.requests)
        reports = sync_export(self.database, self.client, export, path=path)
        asset_requests = [
            request
            for request in self.fake.requests[before:]
            if request.path.endswith("/assets")
        ]
        self.assertEqual(asset_requests, [])
        self.assertTrue(all(report.reconciled for report in reports))

    def test_removals_are_issued_before_additions(self):
        self.fake.albums["foreign"] = {
            "id": "foreign",
            "albumName": "triage-delete",
            "description": "",
            "assetIds": ["k1"],
        }
        # Adopt the empty album through the snapshot so the diff has both sides.
        self.database.set_album("delete", "foreign", None)
        self.database.replace_album_members("delete", ["k1"], 0)
        export, path = self.export()
        sync_export(self.database, self.client, export, path=path)
        asset_requests = [
            request.method
            for request in self.fake.requests
            if request.path.endswith("/assets")
        ]
        self.assertEqual(asset_requests[:2], ["DELETE", "PUT"])

    def test_partial_failure_is_reported_and_retried(self):
        self.fake.set_fail_add({"r1"})
        export, path = self.export()
        reports = sync_export(self.database, self.client, export, path=path)
        review = reports[1]
        self.assertFalse(review.reconciled)
        self.assertEqual(review.failures[0]["id"], "r1")
        review_id = self.database.album("review")["immich_album_id"]
        self.assertEqual(self.fake.album_asset_ids(review_id), [])
        self.assertEqual(self.database.album_members("review"), [])
        self.fake.set_fail_add(set())
        reports = sync_export(self.database, self.client, export, path=path)
        self.assertTrue(reports[1].reconciled)
        self.assertEqual(self.fake.album_asset_ids(review_id), ["r1"])

    def test_reconcile_detects_a_count_mismatch(self):
        class LyingClient(ImmichClient):
            def album(self, album_id):
                payload = super().album(album_id)
                payload["assetCount"] = int(payload.get("assetCount", 0)) + 1
                return payload

        export, path = self.export()
        client = LyingClient(socket_path=self.socket, api_key="album-key")
        reports = sync_export(self.database, client, export, path=path, reconcile=True)
        self.assertFalse(reports[0].reconciled)
        self.assertEqual(reports[0].failures[0]["error"], "count_mismatch")

    def test_album_key_permissions_are_exact(self):
        fake = FakeImmich(
            assets=[{"id": "d1"}],
            keys={
                "album-key": sorted(ALBUM_PERMISSIONS | {"asset.read"}),
                "missing-key": sorted(ALBUM_PERMISSIONS - {"album.create"}),
            },
            api_key="album-key",
            unix_path=self.socket + ".extra",
        )
        fake.start()
        try:
            client = ImmichClient(socket_path=self.socket + ".extra", api_key="album-key")
            with self.assertRaises(ImmichPermissionError):
                client.assert_album_permissions()
            client = ImmichClient(
                socket_path=self.socket + ".extra", api_key="missing-key"
            )
            with self.assertRaises(ImmichPermissionError):
                client.assert_album_permissions()
        finally:
            fake.stop()

    def test_preflight_proves_scopes_and_leaves_the_album_empty(self):
        result = preflight(self.client, probe_asset_id="p1")
        self.assertTrue(result["ok"])
        review_id = result["albums"]["review"]["album_id"]
        self.assertEqual(self.fake.album_asset_ids(review_id), [])
        self.assertTrue(all(item["created"] for item in result["albums"].values()))

    def test_preflight_add_is_retried(self):
        self.fake.queue_failure(502, count=1, method="PUT", path_prefix="/api/albums/")
        result = preflight(
            self.client, probe_asset_id="p1", sleep=lambda _: None
        )
        self.assertTrue(result["ok"])
        self.assertEqual(
            self.fake.album_asset_ids(result["albums"]["review"]["album_id"]), []
        )

    def test_preflight_refuses_an_existing_member(self):
        album_id = self.client.create_album(ALBUM_NAMES["review"])["id"]
        self.client.add_album_assets(album_id, ["p1"])
        with self.assertRaises(AlbumError):
            preflight(self.client, probe_asset_id="p1")
        self.assertEqual(self.fake.album_asset_ids(album_id), ["p1"])

    def test_refuses_to_adopt_a_nonempty_foreign_album(self):
        self.fake.albums["foreign"] = {
            "id": "foreign",
            "albumName": "triage-delete",
            "description": "",
            "assetIds": ["k1"],
        }
        export, path = self.export()
        with self.assertRaises(AlbumError):
            sync_export(self.database, self.client, export, path=path)

    def test_deleted_album_is_recreated_and_ui_rename_keeps_the_id(self):
        export, path = self.export()
        sync_export(self.database, self.client, export, path=path)
        album_id = self.database.album("delete")["immich_album_id"]
        self.fake.albums[album_id]["albumName"] = "renamed by the UI"
        sync_export(self.database, self.client, export, path=path)
        self.assertEqual(self.database.album("delete")["immich_album_id"], album_id)
        self.fake.albums.pop(album_id)
        sync_export(self.database, self.client, export, path=path)
        new_id = self.database.album("delete")["immich_album_id"]
        self.assertNotEqual(new_id, album_id)
        self.assertEqual(self.fake.album_asset_ids(new_id), ["d1"])

    def test_status_reports_the_local_snapshot(self):
        export, path = self.export()
        sync_export(self.database, self.client, export, path=path)
        status = album_status(self.database)
        self.assertEqual(status["delete"]["members"], 1)
        self.assertEqual(status["review"]["members"], 1)

    def test_cli_status_dry_run_and_live_sync(self):
        export, path = self.export()
        keys = (
            "PHOTO_TRIAGE_DATA_DIR",
            "PHOTO_TRIAGE_IMMICH_ALBUM_SOCKET",
            "CREDENTIALS_DIRECTORY",
        )
        old = {key: os.environ.get(key) for key in keys}
        credentials = Path(self._tmp.name, "credentials")
        credentials.mkdir()
        Path(credentials, "immich-album-key").write_text("album-key")
        os.environ["PHOTO_TRIAGE_DATA_DIR"] = self._tmp.name
        os.environ["PHOTO_TRIAGE_IMMICH_ALBUM_SOCKET"] = self.socket
        try:
            os.environ.pop("CREDENTIALS_DIRECTORY", None)
            with redirect_stdout(io.StringIO()) as out:
                self.assertEqual(main(["albums", "status"]), 0)
            self.assertIn("delete", json.loads(out.getvalue()))
            with redirect_stdout(io.StringIO()):
                self.assertEqual(
                    main(["albums", "sync", "--dry-run", "--export", str(path)]), 0
                )
            self.assertEqual(self.fake.requests, [])
            os.environ["CREDENTIALS_DIRECTORY"] = str(credentials)
            with redirect_stdout(io.StringIO()) as out:
                self.assertEqual(main(["albums", "sync", "--export", str(path)]), 0)
            reports = json.loads(out.getvalue())["reports"]
            self.assertTrue(all(report["reconciled"] for report in reports))
            delete_id = self.database.album("delete")["immich_album_id"]
            self.assertEqual(self.fake.album_asset_ids(delete_id), ["d1"])
            run = self.database.connection.execute(
                "SELECT state, stats_json FROM runs WHERE kind = 'albums' ORDER BY id DESC LIMIT 1"
            ).fetchone()
            self.assertEqual(run["state"], "complete")
            self.assertEqual(json.loads(run["stats_json"])["decide_run_id"], export["run_id"])
        finally:
            for key, value in old.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value


if __name__ == "__main__":
    unittest.main()
