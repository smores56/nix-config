import io
import json
import os
import sqlite3
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "modules/features/ai/memory/src"))

from memory_mcp import cli, export  # noqa: E402
from memory_mcp.export import (  # noqa: E402
    ExportConfig,
    ExportError,
    ExportInvalid,
    GraphSnapshotError,
    RestoreConfig,
    file_sha256,
    is_snapshot_name,
    parse_info,
    prune_exports,
    restore,
    run_export,
    snapshot_graph,
    snapshot_registry,
    status_counts,
    timestamp,
    verify_export,
    write_episodes,
)
from memory_mcp.registry import SCHEMA_VERSION, Registry, RegistryEpisode  # noqa: E402

STAMP = "2026-10-22T03-00-00Z"


def make_entry(index: int, *, group: str = "owner--repo", status: str = "active") -> RegistryEpisode:
    digest = f"{index:064x}"
    return RegistryEpisode(
        group=group,
        content_hash=digest,
        uuid=f"uuid-{index}",
        name=f"episode {index}",
        content=f"content {index}",
        kind="text",
        origin="sdlc",
        origin_ref=f"issue-{index}",
        actor="cli",
        cwd="/home/smores/code/x",
        tags=("decision",),
        valid_at="2026-10-01T00:00:00Z",
        created_at=f"2026-10-0{index}T00:00:00Z",
        status=status,
        attempts=0,
        graphiti_uuid=f"graph-{index}",
    )


def build_state(state_dir: Path, entries: list[RegistryEpisode]) -> Path:
    """Insert rows verbatim (queue() would reset status and graph identity)."""
    registry = Registry(str(state_dir))
    with registry._connect() as conn:
        for entry in entries:
            registry._insert(conn, entry)
    return state_dir / "registry.sqlite"


class FakeRedis:
    """Just enough of the redis client for BGSAVE plus INFO persistence."""

    def __init__(self, replies: list[str], *, bgsave_error: Exception | None = None) -> None:
        self.replies = list(replies)
        self.bgsave_error = bgsave_error
        self.commands: list[tuple[object, ...]] = []

    def execute_command(self, *args: object) -> object:
        self.commands.append(args)
        if args[0] == "BGSAVE":
            if self.bgsave_error is not None:
                raise self.bgsave_error
            return "Background saving started"
        if tuple(args) == ("INFO", "persistence"):
            return self.replies.pop(0) if len(self.replies) > 1 else self.replies[0]
        raise AssertionError(f"unexpected command {args}")


IN_PROGRESS = "# Persistence\r\nrdb_bgsave_in_progress:1\r\nrdb_last_bgsave_status:ok\r\n"
FINISHED = "# Persistence\r\nrdb_bgsave_in_progress:0\r\nrdb_last_bgsave_status:ok\r\n"


class TimestampTests(unittest.TestCase):
    def test_timestamp_is_sortable_and_filename_safe(self):
        moment = datetime(2026, 10, 22, 3, 4, 5, tzinfo=timezone.utc)
        self.assertEqual(timestamp(moment), "2026-10-22T03-04-05Z")
        self.assertTrue(is_snapshot_name(timestamp(moment)))

    def test_only_export_names_are_snapshot_names(self):
        for name in ("2026-10-22", "graph-2026-10-22T03-00-00Z.rdb", "latest", "2026-10-22T03-00-00Z.bak"):
            with self.subTest(name=name):
                self.assertFalse(is_snapshot_name(name))


class RegistrySnapshotTests(unittest.TestCase):
    def test_snapshot_excludes_uncommitted_writes(self):
        """The backup API reads one committed state; it never blocks the writer."""
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "state"
            db = build_state(state, [make_entry(1)])
            writer = sqlite3.connect(db)
            try:
                writer.execute("PRAGMA journal_mode=WAL")
                writer.execute(
                    "INSERT INTO episodes (group_id, content_hash, uuid, name, content, valid_at, created_at)"
                    " VALUES ('owner--repo', 'uncommitted', 'u', 'n', 'c', '2026-10-02T00:00:00Z',"
                    " '2026-10-02T00:00:00Z')"
                )
                with tempfile.TemporaryDirectory() as scratch:
                    snapshot = Path(scratch) / "registry.sqlite"
                    snapshot_registry(db, snapshot)
                    self.assertEqual(status_counts(snapshot)["total"], 1)
                writer.commit()
                with tempfile.TemporaryDirectory() as scratch:
                    snapshot = Path(scratch) / "registry.sqlite"
                    snapshot_registry(db, snapshot)
                    self.assertEqual(status_counts(snapshot)["total"], 2)
            finally:
                writer.close()

    def test_snapshot_requires_a_registry(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ExportError):
                snapshot_registry(Path(directory) / "missing.sqlite", Path(directory) / "out.sqlite")

    def test_episodes_jsonl_carries_typed_provenance_and_content(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "state"
            db = build_state(state, [make_entry(1)])
            target = Path(directory) / "episodes.jsonl"
            self.assertEqual(write_episodes(db, target), 1)
            record = json.loads(target.read_text(encoding="utf-8").strip())
        for key in (
            "group",
            "uuid",
            "content_hash",
            "kind",
            "origin",
            "origin_ref",
            "actor",
            "cwd",
            "tags",
            "valid_at",
            "created_at",
            "status",
            "graphiti_uuid",
            "promoted_from_group",
            "promoted_by",
            "promoted_at",
            "tombstoned_at",
            "tombstone_reason",
            "content",
        ):
            self.assertIn(key, record)
        self.assertEqual(record["group"], "owner--repo")
        self.assertEqual(record["tags"], ["decision"])
        self.assertEqual(record["content"], "content 1")

    def test_unversioned_registry_is_refused_by_export(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "state"
            state.mkdir()
            db = state / "registry.sqlite"
            conn = sqlite3.connect(db)
            conn.execute("CREATE TABLE episodes (x INTEGER)")
            conn.commit()
            conn.close()
            with self.assertRaises(ExportError) as caught:
                run_export(ExportConfig(root=Path(directory) / "exports", state_dir=state))
        self.assertIn("schema version", str(caught.exception))
        self.assertFalse((Path(directory) / "exports").exists() and any((Path(directory) / "exports").iterdir()))


class GraphSnapshotTests(unittest.TestCase):
    def setUp(self) -> None:
        self.scratch = tempfile.TemporaryDirectory()
        self.root = Path(self.scratch.name)
        self.graph_dir = self.root / "falkordb"
        self.graph_dir.mkdir()
        self.export_dir = self.root / "export"
        self.export_dir.mkdir()
        (self.graph_dir / "dump.rdb").write_bytes(b"RDBfake")

    def tearDown(self) -> None:
        self.scratch.cleanup()

    def snapshot(self, client, **kwargs):
        return snapshot_graph(
            graph_dir=self.graph_dir,
            dest_dir=self.export_dir,
            snapshot=STAMP,
            client=client,
            sleep=lambda _seconds: None,
            **kwargs,
        )

    def test_bgsave_is_polled_until_it_finishes(self):
        client = FakeRedis([IN_PROGRESS, FINISHED])
        result = self.snapshot(client, timeout=5.0)
        self.assertEqual(result.file, f"graph-{STAMP}.rdb")
        self.assertEqual(result.snapshot, STAMP)
        target = self.export_dir / result.file
        self.assertEqual(target.read_bytes(), b"RDBfake")
        self.assertEqual(result.sha256, file_sha256(target))
        self.assertEqual(
            [command[0] for command in client.commands], ["BGSAVE", "INFO", "INFO"]
        )

    def test_an_already_running_save_is_tolerated(self):
        client = FakeRedis([FINISHED], bgsave_error=RuntimeError("Background save already in progress"))
        self.assertTrue(self.snapshot(client, timeout=5.0).file)

    def test_a_failing_bgsave_is_an_error(self):
        client = FakeRedis([FINISHED], bgsave_error=RuntimeError("MISCONF"))
        with self.assertRaises(GraphSnapshotError) as caught:
            self.snapshot(client, timeout=5.0)
        self.assertIn("BGSAVE failed", str(caught.exception))

    def test_a_slow_save_times_out(self):
        client = FakeRedis([IN_PROGRESS])
        with self.assertRaises(GraphSnapshotError) as caught:
            self.snapshot(client, timeout=0.0)
        self.assertIn("did not finish", str(caught.exception))

    def test_a_failed_save_is_reported(self):
        client = FakeRedis(["rdb_bgsave_in_progress:0\r\nrdb_last_bgsave_status:err\r\n"])
        with self.assertRaises(GraphSnapshotError) as caught:
            self.snapshot(client, timeout=1.0)
        self.assertIn("BGSAVE failed", str(caught.exception))

    def test_a_stale_dump_is_not_taken_for_this_save(self):
        ancient = 1_000_000
        os.utime(self.graph_dir / "dump.rdb", (ancient, ancient))
        with self.assertRaises(GraphSnapshotError) as caught:
            self.snapshot(FakeRedis([FINISHED]), timeout=1.0)
        self.assertIn("not rewritten", str(caught.exception))

    def test_a_missing_dump_is_an_error(self):
        (self.graph_dir / "dump.rdb").unlink()
        with self.assertRaises(GraphSnapshotError) as caught:
            self.snapshot(FakeRedis([FINISHED]), timeout=1.0)
        self.assertIn("not readable", str(caught.exception))

    def test_parse_info_keeps_only_key_values(self):
        fields = parse_info("# Persistence\r\naof_enabled:1\r\nrdb_bgsave_in_progress:0\r\n\r\n")
        self.assertEqual(fields, {"aof_enabled": "1", "rdb_bgsave_in_progress": "0"})


class ExportTests(unittest.TestCase):
    def test_export_writes_a_verifiable_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / "state"
            build_state(state, [make_entry(1), make_entry(2, group="global", status="tombstoned")])
            result = run_export(ExportConfig(root=root / "exports", state_dir=state, keep=7))
            manifest = json.loads((result.directory / "manifest.json").read_text())
            self.assertEqual(manifest["snapshot"], result.directory.name)
            self.assertEqual(manifest["schema_version"], SCHEMA_VERSION)
            self.assertEqual(
                manifest["counts"],
                {"total": 2, "active": 1, "pending": 0, "failed": 0, "tombstoned": 1},
            )
            self.assertIsNone(manifest["graph"])
            verified = verify_export(result.directory)
        self.assertEqual(verified.snapshot, manifest["snapshot"])
        self.assertEqual(verified.counts["total"], 2)
        self.assertFalse(verified.graph.accepted)
        self.assertIn("no graph snapshot", verified.graph.reason)

    def test_a_failed_graph_snapshot_still_exports_the_registry(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / "state"
            build_state(state, [make_entry(1)])
            graph_dir = root / "falkordb"
            graph_dir.mkdir()
            (graph_dir / "dump.rdb").write_bytes(b"RDBfake")
            result = run_export(
                ExportConfig(
                    root=root / "exports",
                    state_dir=state,
                    graph_dir=graph_dir,
                    graph_client=FakeRedis([IN_PROGRESS], bgsave_error=None),
                    graph_timeout=0.0,
                )
            )
            manifest = json.loads((result.directory / "manifest.json").read_text())
            self.assertIsNone(manifest["graph"])
            self.assertIn("did not finish", manifest["graph_error"])
            self.assertTrue((result.directory / "registry.sqlite").is_file())
        self.assertEqual(manifest["counts"]["total"], 1)

    def test_a_successful_graph_snapshot_is_recorded(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / "state"
            build_state(state, [make_entry(1)])
            graph_dir = root / "falkordb"
            graph_dir.mkdir()
            (graph_dir / "dump.rdb").write_bytes(b"RDBfake")
            result = run_export(
                ExportConfig(
                    root=root / "exports",
                    state_dir=state,
                    graph_dir=graph_dir,
                    graph_client=FakeRedis([FINISHED]),
                )
            )
            manifest = json.loads((result.directory / "manifest.json").read_text())
            graph = manifest["graph"]
            self.assertEqual(graph["file"], f"graph-{manifest['snapshot']}.rdb")
            self.assertEqual(graph["timestamp"], manifest["snapshot"])
            verified = verify_export(result.directory)
        self.assertTrue(verified.graph.accepted)
        self.assertEqual(verified.graph.path.name, graph["file"])

    def test_an_unusable_retention_count_is_refused_before_writing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / "state"
            build_state(state, [make_entry(1)])
            with self.assertRaises(ExportError):
                run_export(ExportConfig(root=root / "exports", state_dir=state, keep=0))
            self.assertFalse((root / "exports").exists())


class PruneTests(unittest.TestCase):
    def test_retention_prunes_only_its_own_directories(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            names = ["2026-10-01T00-00-00Z", "2026-10-02T00-00-00Z", "2026-10-03T00-00-00Z"]
            for name in names:
                (root / name).mkdir()
            (root / "operator-notes").mkdir()
            (root / "2026-10-04T00-00-00Z.txt").write_text("not an export")
            (root / "latest").symlink_to(root / names[-1])
            pruned = prune_exports(root, 2)
            remaining = sorted(path.name for path in root.iterdir())
        self.assertEqual([path.name for path in pruned], [names[0]])
        self.assertEqual(remaining, sorted([names[1], names[2], "operator-notes", "2026-10-04T00-00-00Z.txt", "latest"]))

    def test_retention_requires_a_positive_count(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError):
                prune_exports(directory, 0)


class RestoreTests(unittest.TestCase):
    def export(self, root: Path, entries: list[RegistryEpisode], **kwargs):
        state = root / "state"
        build_state(state, entries)
        return run_export(ExportConfig(root=root / "exports", state_dir=state, keep=7, **kwargs))

    def restore(self, directory: Path, root: Path, **kwargs):
        return restore(
            RestoreConfig(
                export_dir=directory,
                state_dir=root / "restored",
                graph_dir=root / "graph",
                stop_services=False,
                # Ownership is a root operation on the live host; temp dirs keep
                # whatever user the test runs as.
                owner=None,
                **kwargs,
            )
        )

    def test_restore_round_trips_the_registry(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = self.export(root, [make_entry(1), make_entry(2, group="global")])
            report = self.restore(result.directory, root)
            restored = Registry(str(root / "restored"))
            self.assertEqual(restored.stats("owner--repo")["total"], 1)
            self.assertEqual(restored.stats("global")["total"], 1)
        self.assertTrue(report.restored)
        self.assertEqual(report.counts["total"], 2)

    def test_restore_replaces_stale_wal_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = self.export(root, [make_entry(1)])
            (root / "restored").mkdir()
            for suffix in ("-wal", "-shm"):
                (root / "restored" / f"registry.sqlite{suffix}").write_text("stale")
            self.restore(result.directory, root)
            remaining = sorted(path.name for path in (root / "restored").iterdir())
        self.assertEqual(remaining, ["registry.sqlite"])

    def test_a_tampered_file_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = self.export(root, [make_entry(1)])
            target = result.directory / "episodes.jsonl"
            target.write_text(target.read_text() + json.dumps({"group": "injected"}) + "\n")
            with self.assertRaises(ExportInvalid) as caught:
                verify_export(result.directory)
            with self.assertRaises(ExportInvalid):
                self.restore(result.directory, root)
            self.assertFalse((root / "restored" / "registry.sqlite").exists())
        self.assertIn("sha256", str(caught.exception))

    def test_a_missing_file_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = self.export(root, [make_entry(1)])
            (result.directory / "registry.sqlite").unlink()
            with self.assertRaises(ExportInvalid) as caught:
                verify_export(result.directory)
        self.assertIn("missing", str(caught.exception))

    def test_a_newer_schema_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = self.export(root, [make_entry(1)])
            db = result.directory / "registry.sqlite"
            conn = sqlite3.connect(db)
            conn.execute(f"PRAGMA user_version = {SCHEMA_VERSION + 1}")
            conn.commit()
            conn.close()
            # Re-seal the manifest so the schema check, not the checksum, refuses.
            manifest = json.loads((result.directory / "manifest.json").read_text())
            manifest["files"]["registry.sqlite"]["sha256"] = file_sha256(db)
            manifest["files"]["registry.sqlite"]["bytes"] = db.stat().st_size
            (result.directory / "manifest.json").write_text(json.dumps(manifest))
            with self.assertRaises(ExportInvalid) as caught:
                self.restore(result.directory, root)
            self.assertFalse((root / "restored" / "registry.sqlite").exists())
        self.assertIn("newer schema", str(caught.exception))

    def test_an_older_schema_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = self.export(root, [make_entry(1)])
            with self.assertRaises(ExportInvalid) as caught:
                restore(
                    RestoreConfig(
                        export_dir=result.directory,
                        state_dir=root / "restored",
                        graph_dir=root / "graph",
                        stop_services=False,
                        owner=None,
                        schema_version=SCHEMA_VERSION + 1,
                    )
                )
        self.assertIn("schema", str(caught.exception))

    def test_a_mismatched_graph_snapshot_falls_back_to_a_rebuild(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            graph_dir = root / "falkordb"
            graph_dir.mkdir()
            (graph_dir / "dump.rdb").write_bytes(b"RDBfake")
            result = self.export(
                root,
                [make_entry(1)],
                graph_dir=graph_dir,
                graph_client=FakeRedis([FINISHED]),
            )
            manifest = json.loads((result.directory / "manifest.json").read_text())
            # Pretend the graph arrived from an earlier run than the registry.
            stale_name = "graph-2026-01-01T00-00-00Z.rdb"
            stale = result.directory / stale_name
            stale.write_bytes(b"RDBstale")
            manifest["graph"] = {
                "file": stale_name,
                "timestamp": "2026-01-01T00-00-00Z",
                "sha256": file_sha256(stale),
                "bytes": stale.stat().st_size,
            }
            (result.directory / "manifest.json").write_text(json.dumps(manifest))
            report = self.restore(result.directory, root)
            graph_dump = root / "graph" / "dump.rdb"
            self.assertFalse(report.graph_restored)
            self.assertFalse(graph_dump.exists())
            self.assertTrue((root / "restored" / "registry.sqlite").is_file())
        self.assertIn("does not belong", report.graph.reason)
        self.assertIn("memory-ingest", export.graph_advice(report))

    def test_a_matching_graph_snapshot_is_restored(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            graph_dir = root / "falkordb"
            graph_dir.mkdir()
            (graph_dir / "dump.rdb").write_bytes(b"RDBfake")
            result = self.export(
                root,
                [make_entry(1)],
                graph_dir=graph_dir,
                graph_client=FakeRedis([FINISHED]),
            )
            report = self.restore(result.directory, root)
            dump = (root / "graph" / "dump.rdb").read_bytes()
        self.assertTrue(report.graph_restored)
        self.assertEqual(dump, b"RDBfake")

    def test_a_matching_restore_parks_the_old_aof(self):
        """FalkorDB loads the AOF first, so the restored RDB needs it out of the way."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            graph_dir = root / "falkordb"
            graph_dir.mkdir()
            (graph_dir / "dump.rdb").write_bytes(b"RDBfake")
            result = self.export(
                root,
                [make_entry(1)],
                graph_dir=graph_dir,
                graph_client=FakeRedis([FINISHED]),
            )
            (root / "graph" / "appendonlydir").mkdir(parents=True)
            (root / "graph" / "appendonlydir" / "appendonly.aof").write_text("old graph")
            report = self.restore(result.directory, root)
            parked = root / "graph" / f"appendonlydir.pre-restore-{report.snapshot}"
            self.assertTrue(parked.is_dir())
            self.assertEqual(report.parked_aof, (parked.name,))
            self.assertEqual((root / "graph" / "dump.rdb").read_bytes(), b"RDBfake")
            self.assertIn("AOF", export.graph_advice(report))

    def test_a_tampered_graph_snapshot_keeps_the_registry(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            graph_dir = root / "falkordb"
            graph_dir.mkdir()
            (graph_dir / "dump.rdb").write_bytes(b"RDBfake")
            result = self.export(
                root,
                [make_entry(1)],
                graph_dir=graph_dir,
                graph_client=FakeRedis([FINISHED]),
            )
            manifest = json.loads((result.directory / "manifest.json").read_text())
            (result.directory / manifest["graph"]["file"]).write_bytes(b"tampered")
            report = self.restore(result.directory, root)
        self.assertFalse(report.graph_restored)
        self.assertIn("sha256", report.graph.reason)

    def test_dry_run_writes_nothing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = self.export(root, [make_entry(1)])
            report = self.restore(result.directory, root, dry_run=True)
            self.assertFalse(report.restored)
            self.assertFalse((root / "restored").exists())

    def test_a_directory_whose_name_is_not_a_timestamp_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = self.export(root, [make_entry(1)])
            renamed = root / "latest"
            result.directory.rename(renamed)
            with self.assertRaises(ExportInvalid):
                verify_export(renamed)


class CliTests(unittest.TestCase):
    def run_cli(self, argv):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = cli.main(argv)
        return code, out.getvalue(), err.getvalue()

    def test_export_and_restore_through_the_cli(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / "state"
            build_state(state, [make_entry(1)])
            code, out, err = self.run_cli(
                ["export", "--root", str(root / "exports"), "--state-dir", str(state)]
            )
            self.assertEqual(code, 0, err)
            self.assertIn("exported", out)
            exported = next((root / "exports").iterdir())
            code, out, err = self.run_cli(
                [
                    "restore",
                    str(exported),
                    "--state-dir",
                    str(root / "restored"),
                    "--graph-dir",
                    str(root / "graph"),
                    "--no-stop",
                ]
            )
            self.assertEqual(code, 0, err)
            self.assertIn("restored", out)
            self.assertTrue((root / "restored" / "registry.sqlite").is_file())

    def test_a_bad_export_exits_one(self):
        with tempfile.TemporaryDirectory() as directory:
            code, _, err = self.run_cli(
                ["export", "--root", str(Path(directory) / "e"), "--state-dir", directory]
            )
            self.assertEqual(code, 1)
            self.assertIn("no registry", err)

    def test_export_json_prints_the_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / "state"
            build_state(state, [make_entry(1)])
            code, out, err = self.run_cli(
                ["--json", "export", "--root", str(root / "exports"), "--state-dir", str(state)]
            )
            self.assertEqual(code, 0, err)
            manifest = json.loads(out)
        self.assertEqual(manifest["counts"]["total"], 1)


if __name__ == "__main__":
    unittest.main()
