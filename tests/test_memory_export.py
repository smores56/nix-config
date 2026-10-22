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
from unittest import mock

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
    """Just enough of the redis client for the save timestamp, BGSAVE, and INFO.

    One reply per `INFO persistence` call, in order, so a test can script the
    probe before the save separately from the polls after it.
    """

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
            if not self.replies:
                raise AssertionError("unscripted INFO persistence call")
            return self.replies.pop(0)
        raise AssertionError(f"unexpected command {args}")


def persistence(
    *, last_save: int = 1_000, in_progress: int = 0, status: str = "ok"
) -> str:
    error = "" if status == "ok" else "\r\nrdb_last_bgsave_err:SOMETHING"
    return (
        f"# Persistence\r\nrdb_last_save_time:{last_save}\r\n"
        f"rdb_bgsave_in_progress:{in_progress}\r\nrdb_last_bgsave_status:{status}{error}\r\n"
    )


BEFORE = persistence(last_save=1_000)
IN_PROGRESS = persistence(last_save=1_000, in_progress=1)
# The save completed, so the server's timestamp of its last save advanced.
FINISHED = persistence(last_save=2_000)


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
        client = FakeRedis([BEFORE, IN_PROGRESS, FINISHED])
        result = self.snapshot(client, timeout=5.0)
        self.assertEqual(result.file, f"graph-{STAMP}.rdb")
        self.assertEqual(result.snapshot, STAMP)
        target = self.export_dir / result.file
        self.assertEqual(target.read_bytes(), b"RDBfake")
        self.assertEqual(result.sha256, file_sha256(target))
        self.assertEqual(
            [command[0] for command in client.commands], ["INFO", "BGSAVE", "INFO", "INFO"]
        )

    def test_an_already_running_save_is_tolerated(self):
        client = FakeRedis([BEFORE, FINISHED], bgsave_error=RuntimeError("Background save already in progress"))
        self.assertTrue(self.snapshot(client, timeout=5.0).file)

    def test_a_failing_bgsave_is_an_error(self):
        client = FakeRedis([BEFORE], bgsave_error=RuntimeError("MISCONF"))
        with self.assertRaises(GraphSnapshotError) as caught:
            self.snapshot(client, timeout=5.0)
        self.assertIn("BGSAVE failed", str(caught.exception))

    def test_a_slow_save_times_out(self):
        client = FakeRedis([BEFORE, IN_PROGRESS])
        with self.assertRaises(GraphSnapshotError) as caught:
            self.snapshot(client, timeout=0.0)
        self.assertIn("did not finish", str(caught.exception))

    def test_a_failed_save_is_reported(self):
        client = FakeRedis([BEFORE, persistence(last_save=2_000, status="err")])
        with self.assertRaises(GraphSnapshotError) as caught:
            self.snapshot(client, timeout=1.0)
        self.assertIn("BGSAVE failed", str(caught.exception))

    def test_a_save_that_does_not_advance_the_timestamp_is_refused(self):
        """A file that predates this save must never be taken for its output."""
        client = FakeRedis([BEFORE, persistence(last_save=1_000)])
        with self.assertRaises(GraphSnapshotError) as caught:
            self.snapshot(client, timeout=1.0)
        self.assertIn("not rewritten", str(caught.exception))
        self.assertFalse((self.export_dir / f"graph-{STAMP}.rdb").exists())

    def test_an_old_file_mtime_is_not_the_staleness_signal(self):
        """Only the server's save timestamp decides; mtime is not consulted."""
        ancient = 1_000_000
        os.utime(self.graph_dir / "dump.rdb", (ancient, ancient))
        result = self.snapshot(FakeRedis([BEFORE, FINISHED]), timeout=1.0)
        self.assertEqual((self.export_dir / result.file).read_bytes(), b"RDBfake")

    def test_a_server_without_save_timestamps_is_an_error(self):
        client = FakeRedis(["# Persistence\r\nrdb_bgsave_in_progress:0\r\n"])
        with self.assertRaises(GraphSnapshotError) as caught:
            self.snapshot(client, timeout=1.0)
        self.assertIn("rdb_last_save_time", str(caught.exception))

    def test_a_missing_dump_is_an_error(self):
        (self.graph_dir / "dump.rdb").unlink()
        with self.assertRaises(GraphSnapshotError) as caught:
            self.snapshot(FakeRedis([BEFORE, FINISHED]), timeout=1.0)
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
                    graph_client=FakeRedis([BEFORE, IN_PROGRESS], bgsave_error=None),
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
                    graph_client=FakeRedis([BEFORE, FINISHED]),
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
    def make_export(self, root: Path, name: str) -> Path:
        """A timestamped directory that reads as a complete export."""
        path = root / name
        path.mkdir()
        (path / "manifest.json").write_text(json.dumps({"snapshot": name}))
        return path

    def test_retention_prunes_only_its_own_directories(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            names = ["2026-10-01T00-00-00Z", "2026-10-02T00-00-00Z", "2026-10-03T00-00-00Z"]
            for name in names:
                self.make_export(root, name)
            (root / "operator-notes").mkdir()
            (root / "2026-10-04T00-00-00Z.txt").write_text("not an export")
            (root / "latest").symlink_to(root / names[-1])
            pruned = prune_exports(root, 2)
            remaining = sorted(path.name for path in root.iterdir())
        self.assertEqual([path.name for path in pruned], [names[0]])
        self.assertEqual(remaining, sorted([names[1], names[2], "operator-notes", "2026-10-04T00-00-00Z.txt", "latest"]))

    def test_a_partial_export_is_not_a_prune_candidate(self):
        """A timestamped directory without a readable manifest is not an export."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("2026-09-01T00-00-00Z", "2026-09-02T00-00-00Z"):
                self.make_export(root, name)
            (root / "2026-09-03T00-00-00Z").mkdir()
            (root / "2026-09-04T00-00-00Z").mkdir()
            (root / "2026-09-04T00-00-00Z" / "manifest.json").write_text("{not json")
            (root / "2026-09-05T00-00-00Z").mkdir()
            (root / "2026-09-05T00-00-00Z" / "manifest.json").write_text("[]")
            pruned = prune_exports(root, 1)
            remaining = sorted(path.name for path in root.iterdir())
        self.assertEqual([path.name for path in pruned], ["2026-09-01T00-00-00Z"])
        for name in ("2026-09-03T00-00-00Z", "2026-09-04T00-00-00Z", "2026-09-05T00-00-00Z"):
            self.assertIn(name, remaining)

    def test_the_directory_just_written_is_never_pruned(self):
        """A clock step can leave the newest export looking oldest; keep it."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("2026-10-02T00-00-00Z", "2026-10-03T00-00-00Z"):
                self.make_export(root, name)
            stepped = self.make_export(root, "2026-09-01T00-00-00Z")
            pruned = prune_exports(root, 1, current=stepped)
            remaining = sorted(path.name for path in root.iterdir())
        self.assertEqual([path.name for path in pruned], ["2026-10-02T00-00-00Z"])
        self.assertIn("2026-09-01T00-00-00Z", remaining)

    def test_the_current_export_counts_toward_keep(self):
        """Excluding it from the candidates must not make retention keep one extra."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("2026-10-01T00-00-00Z", "2026-10-02T00-00-00Z", "2026-10-03T00-00-00Z"):
                self.make_export(root, name)
            current = root / "2026-10-03T00-00-00Z"
            pruned = prune_exports(root, 2, current=current)
            remaining = sorted(path.name for path in root.iterdir())
        self.assertEqual([path.name for path in pruned], ["2026-10-01T00-00-00Z"])
        self.assertEqual(remaining, ["2026-10-02T00-00-00Z", "2026-10-03T00-00-00Z"])

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
                graph_client=FakeRedis([BEFORE, FINISHED]),
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
        advice = export.graph_advice(report)
        # `memory-ingest` skips rows that already exist, so a restored registry
        # cannot be re-ingested into an empty graph: the advice must say so.
        self.assertIn("memory-rebuild", advice)
        self.assertIn("wipe both stores", advice)
        self.assertNotIn("rebuild it from the restored registry", advice)

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
                graph_client=FakeRedis([BEFORE, FINISHED]),
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
                graph_client=FakeRedis([BEFORE, FINISHED]),
            )
            (root / "graph" / "appendonlydir").mkdir(parents=True)
            (root / "graph" / "appendonlydir" / "appendonly.aof").write_text("old graph")
            report = self.restore(result.directory, root)
            parked = root / "graph" / f"appendonlydir.pre-restore-{report.snapshot}"
            self.assertTrue(parked.is_dir())
            self.assertEqual(report.parked_aof, (parked.name,))
            self.assertEqual((root / "graph" / "dump.rdb").read_bytes(), b"RDBfake")
            advice = export.graph_advice(report)
            self.assertIn("AOF", advice)
            self.assertIn("delete it once", advice)

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
                graph_client=FakeRedis([BEFORE, FINISHED]),
            )
            manifest = json.loads((result.directory / "manifest.json").read_text())
            (result.directory / manifest["graph"]["file"]).write_bytes(b"tampered")
            report = self.restore(result.directory, root)
        self.assertFalse(report.graph_restored)
        self.assertIn("sha256", report.graph.reason)

    def test_restore_parks_the_live_registry_and_its_sidecars(self):
        """The previous registry is copied aside before the swap, WAL included."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = self.export(root, [make_entry(1)])
            state = root / "restored"
            state.mkdir()
            (state / "registry.sqlite").write_bytes(b"previous registry")
            for suffix in ("-wal", "-shm"):
                (state / f"registry.sqlite{suffix}").write_text(f"stale{suffix}")
            report = self.restore(result.directory, root)
            parked = state / f"registry.sqlite.pre-restore-{report.snapshot}"
            leaked = sorted(
                path.name for path in state.iterdir() if path.name.endswith(".restore-tmp")
            )
            live = sorted(path.name for path in state.iterdir())
            self.assertEqual(report.parked_registry[0], parked)
            self.assertEqual(parked.read_bytes(), b"previous registry")
            self.assertEqual(
                (state / f"{parked.name}-wal").read_text(), "stale-wal"
            )
            self.assertEqual(
                (state / f"{parked.name}-shm").read_text(), "stale-shm"
            )
            # The replaced database's sidecars are gone; the restore's own WAL
            # is what the wrapper will open.
            self.assertEqual(leaked, [])
            self.assertNotIn("registry.sqlite-wal", live)
            self.assertNotIn("registry.sqlite-shm", live)
            self.assertIn("registry.sqlite", live)

    def test_a_failed_install_keeps_the_previous_registry(self):
        """Ownership is settled before the swap, and a failure aborts the swap."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = self.export(root, [make_entry(1)])
            state = root / "restored"
            state.mkdir()
            (state / "registry.sqlite").write_bytes(b"previous registry")
            (state / "registry.sqlite-wal").write_text("stale-wal")
            with self.assertRaises(ExportError) as caught:
                restore(
                    RestoreConfig(
                        export_dir=result.directory,
                        state_dir=state,
                        graph_dir=root / "graph",
                        stop_services=False,
                        owner="memory-pre-restore-does-not-exist",
                    )
                )
            parked = state / f"registry.sqlite.pre-restore-{result.directory.name}"
            self.assertEqual((state / "registry.sqlite").read_bytes(), b"previous registry")
            self.assertTrue((state / "registry.sqlite-wal").is_file())
            self.assertTrue(parked.is_file())
            self.assertTrue((state / ".restore-in-progress").is_file())
            self.assertFalse((state / "registry.sqlite.restore-tmp").exists())
        message = str(caught.exception)
        self.assertIn("does not exist", message)
        self.assertIn(str(parked), message)
        self.assertIn(".restore-in-progress", message)

    def test_services_stop_before_the_swap_and_falkordb_restarts_after(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            graph_dir = root / "falkordb"
            graph_dir.mkdir()
            (graph_dir / "dump.rdb").write_bytes(b"RDBfake")
            result = self.export(
                root,
                [make_entry(1)],
                graph_dir=graph_dir,
                graph_client=FakeRedis([BEFORE, FINISHED]),
            )
            commands: list[tuple[str, ...]] = []
            report = restore(
                RestoreConfig(
                    export_dir=result.directory,
                    state_dir=root / "restored",
                    graph_dir=root / "graph",
                    owner=None,
                    run=commands.append,
                )
            )
        self.assertEqual(
            commands[0],
            ("systemctl", "stop", "memory-mcp", "memory-graphiti-mcp", "memory-llm-proxy", "memory-falkordb"),
        )
        # The restored RDB is inert until FalkorDB starts, so its restart is
        # part of the restore, and `graph: restored` is reported after it.
        self.assertEqual(commands[1], ("systemctl", "start", "memory-falkordb"))
        self.assertEqual(report.restarted, ("memory-falkordb",))
        # The writers stay down on purpose, so the advice still asks for them.
        self.assertIn("start the memory services", export.graph_advice(report))
        self.assertIn("restarted memory-falkordb", export.graph_advice(report))

    def test_a_registry_only_restore_does_not_start_the_services(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = self.export(root, [make_entry(1)])
            commands: list[tuple[str, ...]] = []
            report = restore(
                RestoreConfig(
                    export_dir=result.directory,
                    state_dir=root / "restored",
                    graph_dir=root / "graph",
                    owner=None,
                    run=commands.append,
                )
            )
        self.assertEqual(commands, [("systemctl", "stop", *export.MEMORY_UNITS)])
        self.assertEqual(report.restarted, ())
        self.assertIn("not restored", export.graph_advice(report))

    def test_start_brings_the_writers_back_in_reverse_stop_order(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            graph_dir = root / "falkordb"
            graph_dir.mkdir()
            (graph_dir / "dump.rdb").write_bytes(b"RDBfake")
            result = self.export(
                root,
                [make_entry(1)],
                graph_dir=graph_dir,
                graph_client=FakeRedis([BEFORE, FINISHED]),
            )
            commands: list[tuple[str, ...]] = []
            restore(
                RestoreConfig(
                    export_dir=result.directory,
                    state_dir=root / "restored",
                    graph_dir=root / "graph",
                    owner=None,
                    start_services=True,
                    run=commands.append,
                )
            )
        self.assertEqual(
            commands[1],
            ("systemctl", "start", "memory-falkordb", "memory-llm-proxy", "memory-graphiti-mcp", "memory-mcp"),
        )

    def test_a_restore_holds_a_lock_that_blocks_exports(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / "state"
            build_state(state, [make_entry(1)])
            result = run_export(ExportConfig(root=root / "exports", state_dir=state, keep=7))
            lock = state / ".restore-in-progress"
            lock.write_text("stale\n")
            with self.assertRaises(ExportError) as caught:
                run_export(ExportConfig(root=root / "exports", state_dir=state, keep=7))
            self.assertIn(".restore-in-progress", str(caught.exception))
            with self.assertRaises(ExportError) as caught:
                restore(
                    RestoreConfig(
                        export_dir=result.directory,
                        state_dir=state,
                        graph_dir=root / "graph",
                        stop_services=False,
                        owner=None,
                    )
                )
            self.assertIn("another restore is running", str(caught.exception))
            lock.unlink()
            restore(
                RestoreConfig(
                    export_dir=result.directory,
                    state_dir=state,
                    graph_dir=root / "graph",
                    stop_services=False,
                    owner=None,
                )
            )
            self.assertFalse(lock.exists())

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


class SidecarTests(unittest.TestCase):
    def test_sidecars_are_adopted_only_once_they_exist(self):
        """The rw fallback writes; ownership must follow the files it creates."""
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "state"
            db = build_state(state, [make_entry(1)])
            seen: list[bool] = []
            adopt = export._adopt_sidecars
            real_connect = export.sqlite3.connect

            def ro_refuses(target, *args, **kwargs):
                if "mode=ro" in str(target):
                    raise sqlite3.OperationalError("unable to open database file")
                return real_connect(target, *args, **kwargs)

            def spy(path):
                seen.append(path.with_name(path.name + "-shm").exists())
                adopt(path)

            export.sqlite3.connect = ro_refuses
            export._adopt_sidecars = spy
            try:
                conn = export._open_source(db)
                conn.close()
            finally:
                export.sqlite3.connect = real_connect
                export._adopt_sidecars = adopt
        self.assertEqual(seen, [True])


class CliTests(unittest.TestCase):
    def run_cli(self, argv):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = cli.main(argv)
        return code, out.getvalue(), err.getvalue()

    def fake_systemctl(self, root: Path) -> tuple[Path, Path]:
        """A `systemctl` on PATH that records its arguments and succeeds."""
        binary = root / "bin"
        binary.mkdir()
        log = root / "systemctl.log"
        script = binary / "systemctl"
        script.write_text(f'#!/bin/sh\nprintf "%s\\n" "$*" >>"{log}"\n')
        script.chmod(0o755)
        return binary, log

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
            binary, log = self.fake_systemctl(root)
            with mock.patch.dict(os.environ, {"PATH": f"{binary}:{os.environ['PATH']}"}):
                code, out, err = self.run_cli(
                    [
                        "restore",
                        str(exported),
                        "--state-dir",
                        str(root / "restored"),
                        "--graph-dir",
                        str(root / "graph"),
                        "--owner",
                        "",
                    ]
                )
            self.assertEqual(code, 0, err)
            self.assertIn("restored", out)
            self.assertTrue((root / "restored" / "registry.sqlite").is_file())
            self.assertEqual(
                log.read_text().splitlines(),
                ["stop memory-mcp memory-graphiti-mcp memory-llm-proxy memory-falkordb"],
            )

    def test_no_stop_without_dry_run_is_refused(self):
        """A real restore stops the services; only a dry run may skip them."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / "state"
            build_state(state, [make_entry(1)])
            exported = run_export(ExportConfig(state_dir=state, root=root / "exports")).directory
            code, _, err = self.run_cli(
                [
                    "restore",
                    str(exported),
                    "--state-dir",
                    str(root / "restored"),
                    "--no-stop",
                ]
            )
            self.assertEqual(code, 1)
            self.assertIn("--no-stop", err)
            self.assertFalse((root / "restored").exists())

    def test_a_failed_graph_snapshot_makes_the_export_exit_one(self):
        """The registry export stands, but the timer must see the failure."""
        result = export.ExportResult(
            directory=Path("/nonexistent/2026-10-22T03-00-00Z"),
            manifest={
                "counts": {"total": 1},
                "graph": None,
                "graph_error": "BGSAVE did not finish within 1s",
            },
            pruned=(),
        )
        with mock.patch.object(export, "run_export", lambda _config: result):
            code, out, err = self.run_cli(
                ["export", "--root", "/nonexistent", "--state-dir", "/nonexistent"]
            )
        self.assertEqual(code, 1)
        self.assertIn("exported", out)
        self.assertIn("did not finish", err)

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
