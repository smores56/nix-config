import grp
import io
import json
import os
import pwd
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
    parse_info,
    restore,
    run_dated_export,
    run_export,
    snapshot_graph,
    snapshot_registry,
    status_counts,
    verify_export,
    write_episodes,
)
from memory_mcp.registry import SCHEMA_VERSION, Registry, RegistryEpisode  # noqa: E402


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
        machine="smorespro",
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

    def __init__(self, replies: list[object], *, bgsave_error: Exception | None = None) -> None:
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




class GraphSnapshotTests(unittest.TestCase):
    def setUp(self) -> None:
        self.scratch = tempfile.TemporaryDirectory()
        self.root = Path(self.scratch.name)
        self.graph_dir = self.root / "falkordb"
        self.graph_dir.mkdir()
        self.target = self.root / "graph.rdb"
        (self.graph_dir / "dump.rdb").write_bytes(b"RDBfake")

    def tearDown(self) -> None:
        self.scratch.cleanup()

    def snapshot(self, client, **kwargs):
        return snapshot_graph(
            graph_dir=self.graph_dir,
            dest=self.target,
            client=client,
            sleep=lambda _seconds: None,
            **kwargs,
        )

    def test_bgsave_is_polled_until_it_finishes(self):
        client = FakeRedis([BEFORE, IN_PROGRESS, FINISHED])
        self.snapshot(client, timeout=5.0)
        self.assertEqual(self.target.read_bytes(), b"RDBfake")
        self.assertEqual(
            [command[0] for command in client.commands], ["INFO", "BGSAVE", "INFO", "INFO"]
        )

    def test_a_parsed_info_mapping_is_accepted(self):
        client = FakeRedis(
            [
                {
                    "rdb_last_save_time": 1_000,
                    "rdb_bgsave_in_progress": 0,
                    "rdb_last_bgsave_status": "ok",
                },
                {
                    "rdb_last_save_time": 2_000,
                    "rdb_bgsave_in_progress": 0,
                    "rdb_last_bgsave_status": "ok",
                },
            ]
        )
        self.snapshot(client, timeout=5.0)
        self.assertTrue(self.target.is_file())

    def test_an_already_running_save_is_tolerated(self):
        client = FakeRedis([BEFORE, FINISHED], bgsave_error=RuntimeError("Background save already in progress"))
        self.snapshot(client, timeout=5.0)
        self.assertTrue(self.target.is_file())

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
        self.assertFalse(self.target.exists())

    def test_an_old_file_mtime_is_not_the_staleness_signal(self):
        """Only the server's save timestamp decides; mtime is not consulted."""
        ancient = 1_000_000
        os.utime(self.graph_dir / "dump.rdb", (ancient, ancient))
        self.snapshot(FakeRedis([BEFORE, FINISHED]), timeout=1.0)
        self.assertEqual(self.target.read_bytes(), b"RDBfake")

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

    def test_parse_info_accepts_a_parsed_mapping(self):
        fields = parse_info({"rdb_last_save_time": 1_000, "rdb_bgsave_in_progress": 0})
        self.assertEqual(fields, {"rdb_last_save_time": "1000", "rdb_bgsave_in_progress": "0"})


def state_with(root: Path, entries: list[RegistryEpisode]) -> Path:
    state = root / "state"
    build_state(state, entries)
    return state


def graph_source(root: Path) -> Path:
    graph_dir = root / "falkordb"
    graph_dir.mkdir()
    (graph_dir / "dump.rdb").write_bytes(b"RDBfake")
    return graph_dir


def export_with_graph(root: Path, entries: list[RegistryEpisode]):
    return run_export(
        ExportConfig(
            root=root / "exports",
            state_dir=state_with(root, entries),
            graph_dir=graph_source(root),
            graph_client=FakeRedis([BEFORE, FINISHED]),
        )
    )


class RegistrySnapshotTests(unittest.TestCase):
    def test_snapshot_excludes_uncommitted_writes(self):
        """The backup API reads one committed state; it never blocks the writer."""
        with tempfile.TemporaryDirectory() as directory:
            db = build_state(Path(directory) / "state", [make_entry(1)])
            writer = sqlite3.connect(db)
            try:
                writer.execute("PRAGMA journal_mode=WAL")
                writer.execute(
                    "INSERT INTO episodes (group_id, content_hash, uuid, name, content, valid_at, created_at)"
                    " VALUES ('owner--repo', 'uncommitted', 'u', 'n', 'c', '2026-10-02T00:00:00Z',"
                    " '2026-10-02T00:00:00Z')"
                )
                snapshot = Path(directory) / "before.sqlite"
                snapshot_registry(db, snapshot)
                self.assertEqual(status_counts(snapshot)["total"], 1)
                writer.commit()
                snapshot = Path(directory) / "after.sqlite"
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
            db = build_state(Path(directory) / "state", [make_entry(1)])
            target = Path(directory) / "episodes.jsonl"
            self.assertEqual(write_episodes(db, target), 1)
            record = json.loads(target.read_text(encoding="utf-8").strip())
        self.assertEqual(record["group"], "owner--repo")
        self.assertEqual(record["origin_ref"], "issue-1")
        self.assertEqual(record["tags"], ["decision"])
        self.assertEqual(record["graphiti_uuid"], "graph-1")
        self.assertEqual(record["machine"], "smorespro")
        self.assertEqual(record["content"], "content 1")

    def test_sidecars_are_adopted_only_once_they_exist(self):
        """The rw fallback writes; ownership must follow the files it creates."""
        with tempfile.TemporaryDirectory() as directory:
            db = build_state(Path(directory) / "state", [make_entry(1)])
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


class ExportTests(unittest.TestCase):
    def test_export_writes_the_registry_and_episodes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = state_with(root, [make_entry(1), make_entry(2, group="global", status="tombstoned")])
            result = run_export(ExportConfig(root=root / "exports", state_dir=state))
            self.assertEqual(sorted(path.name for path in result.directory.iterdir()), ["episodes.jsonl", "registry.sqlite"])
            self.assertEqual(
                result.counts,
                {"total": 2, "active": 1, "pending": 0, "failed": 0, "tombstoned": 1},
            )
            self.assertFalse(result.graph)

    def test_a_second_export_replaces_the_first_in_place(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = state_with(root, [make_entry(1)])
            config = ExportConfig(root=root / "exports", state_dir=state)
            run_export(config)
            with Registry(str(state))._connect() as conn:
                conn.execute("DELETE FROM episodes")
            result = run_export(config)
            self.assertEqual(status_counts(result.directory / "registry.sqlite")["total"], 0)

    def test_a_failed_graph_snapshot_still_exports_the_registry(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = run_export(
                ExportConfig(
                    root=root / "exports",
                    state_dir=state_with(root, [make_entry(1)]),
                    graph_dir=graph_source(root),
                    graph_client=FakeRedis([BEFORE, IN_PROGRESS]),
                    graph_timeout=0.0,
                )
            )
            self.assertIn("did not finish", result.graph_error)
            self.assertTrue((result.directory / "registry.sqlite").is_file())
            self.assertFalse((result.directory / "graph.rdb").exists())

    def test_a_failed_graph_snapshot_never_leaves_the_previous_graph_beside_the_new_registry(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = export_with_graph(root, [make_entry(1)])
            self.assertTrue((first.directory / "graph.rdb").is_file())
            result = run_export(
                ExportConfig(
                    root=root / "exports",
                    state_dir=root / "state",
                    graph_dir=root / "falkordb",
                    graph_client=FakeRedis([BEFORE, IN_PROGRESS]),
                    graph_timeout=0.0,
                )
            )
            self.assertFalse((result.directory / "graph.rdb").exists())

    def test_a_successful_graph_snapshot_is_exported(self):
        with tempfile.TemporaryDirectory() as directory:
            result = export_with_graph(Path(directory), [make_entry(1)])
            self.assertTrue(result.graph)
            self.assertEqual((result.directory / "graph.rdb").read_bytes(), b"RDBfake")

    def test_a_failed_registry_snapshot_leaves_the_previous_pair_intact(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = export_with_graph(root, [make_entry(1)])
            before = (first.directory / "registry.sqlite").read_bytes()
            with sqlite3.connect(root / "state" / "registry.sqlite") as conn:
                conn.execute(f"PRAGMA user_version = {SCHEMA_VERSION + 1}")
            with self.assertRaises(ExportError):
                run_export(ExportConfig(root=first.directory, state_dir=root / "state"))
            self.assertEqual((first.directory / "registry.sqlite").read_bytes(), before)
            self.assertEqual((first.directory / "graph.rdb").read_bytes(), b"RDBfake")

    def test_stale_staging_directories_are_removed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = state_with(root, [make_entry(1)])
            stale = root / "exports" / ".staging-crashed"
            stale.mkdir(parents=True)
            (stale / "registry.sqlite").write_bytes(b"half")
            run_export(ExportConfig(root=root / "exports", state_dir=state))
            self.assertFalse(stale.exists())

    def test_unversioned_registry_is_refused_by_export(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "state"
            state.mkdir()
            conn = sqlite3.connect(state / "registry.sqlite")
            conn.execute("CREATE TABLE episodes (x INTEGER)")
            conn.commit()
            conn.close()
            exports = Path(directory) / "exports"
            with self.assertRaises(ExportError) as caught:
                run_export(ExportConfig(root=exports, state_dir=state))
            self.assertEqual(sorted(path.name for path in exports.iterdir()), [])
        self.assertIn("schema version", str(caught.exception))


class DatedExportTests(unittest.TestCase):
    def dated(self, root: Path, state: Path, stamp: str, keep: int = 7):
        moment = datetime.strptime(stamp, export.TIMESTAMP_FORMAT).replace(tzinfo=timezone.utc)
        return run_dated_export(ExportConfig(root=root / "exports", state_dir=state), keep=keep, now=moment)

    def names(self, root: Path) -> list[str]:
        return sorted(path.name for path in (root / "exports").iterdir())

    def test_each_export_lands_in_its_own_dated_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = state_with(root, [make_entry(1)])
            first = self.dated(root, state, "2026-11-01T03-17-00Z")
            second = self.dated(root, state, "2026-11-02T03-17-00Z")
            self.assertEqual(first.directory.name, "2026-11-01T03-17-00Z")
            self.assertEqual(self.names(root), ["2026-11-01T03-17-00Z", "2026-11-02T03-17-00Z"])
            self.assertTrue((second.directory / "registry.sqlite").is_file())

    def test_only_the_newest_keep_exports_survive(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = state_with(root, [make_entry(1)])
            for day in range(1, 10):
                self.dated(root, state, f"2026-11-0{day}T03-17-00Z", keep=7)
            self.assertEqual(
                self.names(root), [f"2026-11-0{day}T03-17-00Z" for day in range(3, 10)]
            )

    def test_pruning_leaves_foreign_entries_alone(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = state_with(root, [make_entry(1)])
            (root / "exports").mkdir()
            (root / "exports" / "notes.txt").write_text("keep me")
            (root / "exports" / "manual-copy").mkdir()
            for day in range(1, 4):
                self.dated(root, state, f"2026-11-0{day}T03-17-00Z", keep=1)
            self.assertEqual(self.names(root), ["2026-11-03T03-17-00Z", "manual-copy", "notes.txt"])

    def test_a_failed_registry_export_prunes_nothing_and_leaves_no_empty_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = state_with(root, [make_entry(1)])
            self.dated(root, state, "2026-11-01T03-17-00Z", keep=1)
            with self.assertRaises(ExportError):
                self.dated(root, root / "missing-state", "2026-11-02T03-17-00Z", keep=1)
            self.assertEqual(self.names(root), ["2026-11-01T03-17-00Z"])

    def graph_run(self, root: Path, state: Path, day: int, *, works: bool, keep: int):
        graph_dir = graph_source(root) if works and not (root / "falkordb").exists() else root / "falkordb"
        return run_dated_export(
            ExportConfig(
                root=root / "exports",
                state_dir=state,
                graph_dir=graph_dir if works else root / "no-graph",
                graph_client=FakeRedis([BEFORE, FINISHED]),
            ),
            keep=keep,
            now=datetime(2026, 11, day, 3, 17, tzinfo=timezone.utc),
        )

    def test_failing_graph_snapshots_still_cap_the_directories(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = state_with(root, [make_entry(1)])
            self.assertIsNone(self.graph_run(root, state, 1, works=True, keep=2).graph_error)
            for day in range(2, 8):
                self.assertIsNotNone(self.graph_run(root, state, day, works=False, keep=2).graph_error)
            # The newest two, plus the one graph-bearing export that every later run lacked.
            self.assertEqual(
                self.names(root),
                ["2026-11-01T03-17-00Z", "2026-11-06T03-17-00Z", "2026-11-07T03-17-00Z"],
            )
            self.assertTrue((root / "exports" / "2026-11-01T03-17-00Z" / "graph.rdb").is_file())

    def test_the_protected_graph_export_moves_on_once_a_newer_one_has_a_graph(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = state_with(root, [make_entry(1)])
            self.graph_run(root, state, 1, works=True, keep=1)
            self.graph_run(root, state, 2, works=False, keep=1)
            self.graph_run(root, state, 3, works=True, keep=1)
            self.assertEqual(self.names(root), ["2026-11-03T03-17-00Z"])

    def test_a_failed_graph_snapshot_with_no_graph_anywhere_prunes_to_keep(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = state_with(root, [make_entry(1)])
            for day in range(1, 5):
                self.graph_run(root, state, day, works=False, keep=2)
            self.assertEqual(self.names(root), ["2026-11-03T03-17-00Z", "2026-11-04T03-17-00Z"])

    def test_an_existing_dated_directory_is_refused_and_left_alone(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = state_with(root, [make_entry(1)])
            self.dated(root, state, "2026-11-01T03-17-00Z")
            marker = root / "exports" / "2026-11-01T03-17-00Z" / "marker"
            marker.write_text("keep")
            with self.assertRaises(ExportError):
                self.dated(root, state, "2026-11-01T03-17-00Z")
            self.assertEqual(marker.read_text(), "keep")
            self.assertTrue((marker.parent / "registry.sqlite").is_file())

    def test_keep_must_be_positive(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaises(ExportError):
                self.dated(root, state_with(root, [make_entry(1)]), "2026-11-01T03-17-00Z", keep=0)

    def test_the_cli_keeps_dated_directories(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = state_with(root, [make_entry(1)])
            out, err = io.StringIO(), io.StringIO()
            with redirect_stdout(out), redirect_stderr(err):
                code = cli.main(["export", "--root", str(root / "exports"), "--state-dir", str(state), "--keep", "2"])
            self.assertEqual(code, 0, err.getvalue())
            (only,) = (root / "exports").iterdir()
            self.assertRegex(only.name, r"^\d{4}-\d\d-\d\dT\d\d-\d\d-\d\dZ$")
            self.assertTrue((only / "registry.sqlite").is_file())


class RestoreTests(unittest.TestCase):
    def restore(self, directory: Path, root: Path, **kwargs):
        return restore(
            RestoreConfig(
                export_dir=directory,
                state_dir=root / "restored",
                graph_dir=root / "graph",
                stop_services=False,
                # Ownership is a root operation on the live host.
                owner=None,
                **kwargs,
            )
        )

    def export(self, root: Path, entries: list[RegistryEpisode]):
        return run_export(ExportConfig(root=root / "exports", state_dir=state_with(root, entries)))

    def test_restore_hands_the_graph_to_the_service_account(self):
        owner = f"{pwd.getpwuid(os.getuid()).pw_name}:{grp.getgrgid(os.getgid()).gr_name}"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = export_with_graph(root, [make_entry(1)])
            restore(
                RestoreConfig(
                    export_dir=result.directory,
                    state_dir=root / "restored",
                    graph_dir=root / "graph",
                    stop_services=False,
                    owner=owner,
                )
            )
            graph = root / "graph"
            self.assertEqual(graph.stat().st_uid, os.getuid())
            self.assertEqual(graph.stat().st_mode & 0o777, 0o700)
            dump = graph / "dump.rdb"
            self.assertEqual(dump.stat().st_uid, os.getuid())
            self.assertEqual(dump.stat().st_mode & 0o777, 0o640)

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

    def test_a_missing_registry_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = self.export(root, [make_entry(1)])
            (result.directory / "registry.sqlite").unlink()
            with self.assertRaises(ExportInvalid):
                self.restore(result.directory, root)
            self.assertFalse((root / "restored").exists())

    def test_a_corrupt_registry_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = self.export(root, [make_entry(1)])
            (result.directory / "registry.sqlite").write_bytes(b"not a database" * 100)
            with self.assertRaises(ExportInvalid):
                self.restore(result.directory, root)
            self.assertFalse((root / "restored").exists())

    def test_a_registry_that_fails_the_integrity_check_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = self.export(root, [make_entry(1)])
            db = result.directory / "registry.sqlite"
            with sqlite3.connect(db) as conn:
                conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            # Dropping an index's schema row leaves its pages orphaned: queries still
            # work, only the integrity check notices.
            conn = sqlite3.connect(db)
            conn.execute("PRAGMA writable_schema = ON")
            conn.execute("DELETE FROM sqlite_master WHERE type = 'index' AND name = 'episodes_queue'")
            conn.commit()
            conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            conn.close()
            with self.assertRaises(ExportInvalid) as caught:
                self.restore(result.directory, root)
            self.assertIn("integrity", str(caught.exception))
            self.assertFalse((root / "restored").exists())

    def test_a_planted_symlink_is_not_followed_when_staging_the_graph(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = export_with_graph(root, [make_entry(1)])
            victim = root / "victim"
            victim.write_text("keep")
            (root / "graph").mkdir()
            (root / "graph" / "dump.rdb.restore-tmp").symlink_to(victim)
            self.restore(result.directory, root)
            self.assertEqual(victim.read_text(), "keep")
            self.assertEqual((root / "graph" / "dump.rdb").read_bytes(), b"RDBfake")
            self.assertFalse((root / "graph" / "dump.rdb").is_symlink())

    def test_other_schema_versions_are_refused(self):
        for version, word in ((SCHEMA_VERSION + 1, "newer"), (1, "older")):
            with self.subTest(version=version), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                result = self.export(root, [make_entry(1)])
                with sqlite3.connect(result.directory / "registry.sqlite") as conn:
                    conn.execute(f"PRAGMA user_version = {version}")
                with self.assertRaises(ExportInvalid) as caught:
                    self.restore(result.directory, root)
                self.assertIn(f"{word} schema", str(caught.exception))
                self.assertFalse((root / "restored").exists())

    def test_a_v2_export_is_migrated_on_restore(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = self.export(root, [make_entry(1)])
            conn = sqlite3.connect(result.directory / "registry.sqlite")
            try:
                conn.execute("ALTER TABLE episodes DROP COLUMN machine")
                conn.execute("PRAGMA user_version = 2")
                conn.commit()
            finally:
                conn.close()
            report = self.restore(result.directory, root)
            restored = Registry(str(root / "restored"))
            self.assertEqual(report.schema_version, 2)
            self.assertEqual(restored.lookup("owner--repo", f"{1:064x}").machine, "")
            with sqlite3.connect(root / "restored/registry.sqlite") as conn:
                version = conn.execute("PRAGMA user_version").fetchone()[0]
        self.assertEqual(version, SCHEMA_VERSION)

    def test_a_matching_graph_snapshot_is_restored(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = export_with_graph(root, [make_entry(1)])
            report = self.restore(result.directory, root)
            dump = (root / "graph" / "dump.rdb").read_bytes()
        self.assertTrue(report.graph_restored)
        self.assertEqual(dump, b"RDBfake")

    def test_an_export_without_a_graph_restores_the_registry_alone(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = self.export(root, [make_entry(1)])
            report = self.restore(result.directory, root)
            self.assertFalse((root / "graph" / "dump.rdb").exists())
        self.assertFalse(report.graph_restored)
        self.assertIn("no graph snapshot", report.graph.reason)
        advice = export.graph_advice(report)
        self.assertIn("memory reindex --all", advice)
        self.assertNotIn("ingest", advice)

    def test_a_dry_run_reports_the_snapshot_it_would_restore(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = export_with_graph(root, [make_entry(1)])
            report = self.restore(result.directory, root, dry_run=True)
            lines = list(export._report_lines(report, dry_run=True))
            self.assertFalse((root / "restored").exists())
        self.assertFalse(report.restored)
        graph_lines = [line for line in lines if line.startswith("graph:")]
        self.assertEqual(len(graph_lines), 1)
        self.assertIn("would restore graph.rdb", graph_lines[0])

    def test_a_graph_restore_parks_the_old_aof(self):
        """FalkorDB loads the AOF first, so the restored RDB needs it out of the way."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = export_with_graph(root, [make_entry(1)])
            (root / "graph" / "appendonlydir").mkdir(parents=True)
            (root / "graph" / "appendonlydir" / "appendonly.aof").write_text("old graph")
            report = self.restore(result.directory, root)
            parked = root / "graph" / f"appendonlydir.pre-restore-{report.snapshot}"
            self.assertTrue(parked.is_dir())
            self.assertEqual(report.parked_aof, (parked.name,))
            self.assertEqual((root / "graph" / "dump.rdb").read_bytes(), b"RDBfake")
            self.assertIn("delete it once", export.graph_advice(report))

    def test_restore_parks_the_live_registry_and_its_sidecars(self):
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
            live = sorted(path.name for path in state.iterdir())
            self.assertEqual(report.parked_registry[0], parked)
            self.assertEqual(parked.read_bytes(), b"previous registry")
            self.assertEqual((state / f"{parked.name}-wal").read_text(), "stale-wal")
            self.assertEqual((state / f"{parked.name}-shm").read_text(), "stale-shm")
            self.assertNotIn("registry.sqlite-wal", live)
            self.assertNotIn("registry.sqlite-shm", live)
            self.assertFalse(any(name.endswith(".restore-tmp") for name in live))

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
            self.assertEqual((state / "registry.sqlite").read_bytes(), b"previous registry")
            self.assertTrue((state / "registry.sqlite-wal").is_file())
            self.assertEqual(len(list(state.glob("registry.sqlite.pre-restore-*"))), 2)
            self.assertTrue((state / ".restore-in-progress").is_file())
            self.assertFalse((state / "registry.sqlite.restore-tmp").exists())
        message = str(caught.exception)
        self.assertIn("does not exist", message)
        self.assertIn(".restore-in-progress", message)

    def test_services_stop_before_the_swap_and_falkordb_restarts_after(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = export_with_graph(root, [make_entry(1)])
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
        self.assertEqual(commands[1], ("systemctl", "start", "memory-falkordb"))
        self.assertEqual(report.restarted, ("memory-falkordb",))
        self.assertIn("start the memory services", export.graph_advice(report))

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

    def test_start_brings_the_writers_back_in_reverse_stop_order(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = export_with_graph(root, [make_entry(1)])
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
            state = state_with(root, [make_entry(1)])
            config = ExportConfig(root=root / "exports", state_dir=state)
            result = run_export(config)
            lock = state / ".restore-in-progress"
            lock.write_text("stale\n")
            with self.assertRaises(ExportError) as caught:
                run_export(config)
            self.assertIn(".restore-in-progress", str(caught.exception))
            restore_config = RestoreConfig(
                export_dir=result.directory,
                state_dir=state,
                graph_dir=root / "graph",
                stop_services=False,
                owner=None,
            )
            with self.assertRaises(ExportError) as caught:
                restore(restore_config)
            self.assertIn("another restore is running", str(caught.exception))
            lock.unlink()
            restore(restore_config)
            self.assertFalse(lock.exists())

    def test_dry_run_writes_nothing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = self.export(root, [make_entry(1)])
            report = self.restore(result.directory, root, dry_run=True)
            self.assertFalse(report.restored)
            self.assertFalse((root / "restored").exists())


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
            state = state_with(root, [make_entry(1)])
            code, out, err = self.run_cli(
                ["export", "--root", str(root / "exports"), "--state-dir", str(state)]
            )
            self.assertEqual(code, 0, err)
            self.assertIn("exported", out)
            binary, log = self.fake_systemctl(root)
            with mock.patch.dict(os.environ, {"PATH": f"{binary}:{os.environ['PATH']}"}):
                code, out, err = self.run_cli(
                    [
                        "restore",
                        str(root / "exports"),
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
            exported = run_export(
                ExportConfig(state_dir=state_with(root, [make_entry(1)]), root=root / "exports")
            ).directory
            code, _, err = self.run_cli(
                ["restore", str(exported), "--state-dir", str(root / "restored"), "--no-stop"]
            )
            self.assertEqual(code, 1)
            self.assertIn("--no-stop", err)
            self.assertFalse((root / "restored").exists())

    def test_a_failed_graph_snapshot_makes_the_export_exit_one(self):
        """The registry export stands, but the timer must see the failure."""
        result = export.ExportResult(
            directory=Path("/nonexistent"),
            counts={"total": 1},
            graph=False,
            graph_error="BGSAVE did not finish within 1s",
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


if __name__ == "__main__":
    unittest.main()
