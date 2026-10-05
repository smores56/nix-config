import importlib.util
import io
import os
import tempfile
import unittest
from pathlib import Path

DATE = "2026-10-03"


def load_module():
    path = Path(__file__).parents[1] / "modules/features/backup/backup.py"
    spec = importlib.util.spec_from_file_location("backup", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeProc:
    """Minimal subprocess.Popen stand-in for run_streaming tests."""

    def __init__(self, lines, code=0):
        self.stdout = io.StringIO("".join(f"{line}\n" for line in lines))
        self.code = code
        self.killed = False

    def wait(self):
        return self.code

    def kill(self):
        self.killed = True


def cfg(
    module,
    base="/var/backup",
    offsite=True,
    pre_backup=None,
    source="/var/lib/media",
    excludes=(),
):
    return module.Dataset(
        name="media",
        source=source,
        backup_root=base,
        offsite=offsite,
        remote="proton",
        rclone_config="/var/lib/backup/rclone.conf",
        pre_backup=pre_backup,
        excludes=excludes,
    )


class BackupTests(unittest.TestCase):
    def setUp(self):
        self.mod = load_module()
        self.tmp = tempfile.TemporaryDirectory()
        self.base = self.tmp.name
        # run_backup refuses an empty/missing source, so give it a real one.
        self.src = Path(self.base) / "src"
        self.src.mkdir()
        (self.src / "one.bin").write_text("x")

    def tearDown(self):
        self.tmp.cleanup()

    def steps(self, **kw):
        return self.mod.build_steps(cfg(self.mod, **kw), DATE)

    def find(self, steps, *needle):
        for step in steps:
            if all(n in step for n in needle):
                return step
        self.fail(f"no step containing {needle}")

    def collector(self, ran):
        def run(argv, capture=False, env=None):
            ran.append(argv)

        return run

    def test_local_copy_is_copy_not_sync_with_versioning(self):
        # Regression guard: `sync` would delete the mirror when a source file
        # disappears; deletion must never propagate into the versioned copy.
        local = self.find(self.steps(), "rclone", "copy")
        self.assertNotIn("sync", local)
        self.assertNotIn("--delete", local)
        self.assertIn("--backup-dir", local)
        self.assertEqual(local[local.index("copy") + 1], "/var/lib/media")
        self.assertEqual(local[local.index("copy") + 2], "/var/backup/media/current")
        self.assertEqual(
            local[local.index("--backup-dir") + 1],
            "/var/backup/media/versions/" + DATE,
        )

    def test_offsite_copy_targets_remote_and_replaces_drafts(self):
        offsite = self.find(self.steps(), "proton:media")
        self.assertIn("--config", offsite)
        self.assertIn("--protondrive-replace-existing-draft=true", offsite)
        self.assertEqual(
            offsite[offsite.index("copy") + 1], "/var/backup/media/current"
        )
        self.assertEqual(offsite[offsite.index("copy") + 2], "proton:media")

    def test_offsite_copy_has_no_backup_dir(self):
        # Versions stay local-only; the offsite mirror is a plain append-only copy.
        offsite = self.find(self.steps(), "proton:media")
        self.assertNotIn("--backup-dir", offsite)

    def test_offsite_disabled_has_no_remote_step_or_check(self):
        steps = self.steps(offsite=False)
        self.assertFalse(any("proton" in step for step in steps))
        self.assertFalse(self.mod.build_check(cfg(self.mod, offsite=False)))

    def test_pre_backup_runs_first_as_a_script(self):
        # A script path, never a shell string: a multi-line snippet as a single
        # ExecStart argument would stop the systemd unit from loading.
        script = "/nix/store/aaaa-backup-photos-pre"
        steps = self.steps(pre_backup=script)
        self.assertEqual(steps[0], [script])

    def test_check_uses_checksum_against_remote(self):
        check = self.mod.build_check(cfg(self.mod))
        self.assertIn("check", check)
        self.assertIn("--checksum", check)
        self.assertEqual(
            check[check.index("--checksum") + 1], "--one-way"
        )
        self.assertEqual(
            check[check.index("--one-way") + 1], "/var/backup/media/current"
        )
        self.assertEqual(check[check.index("--one-way") + 2], "proton:media")

    def test_check_is_one_way_so_remote_extras_do_not_wedge(self):
        # The remote is append-only, so it may hold files the mirror no longer
        # does; a two-way check would flag those harmless extras as differences.
        self.assertIn("--one-way", self.mod.build_check(cfg(self.mod)))

    def test_require_source_rejects_missing_and_empty(self):
        for bad in (str(Path(self.base) / "nope"), str(self.src / "empty")):
            if bad.endswith("empty"):
                os.makedirs(bad)
            with self.assertRaises(self.mod.BackupError):
                self.mod.require_source(cfg(self.mod, source=bad))
        self.mod.require_source(cfg(self.mod, source=str(self.src)))

    def test_resolve_date_avoids_clobbering_a_same_day_version(self):
        import datetime
        import os as _os

        c = cfg(self.mod, self.base)
        # No folder yet: the plain date is used.
        self.assertEqual(self.mod.resolve_date(c, DATE), DATE)
        # A run earlier the same day leaves the folder; the next run must not
        # reuse it or rclone's --backup-dir would overwrite that version.
        _os.makedirs(self.mod.versions_dir(c, DATE))
        now = datetime.datetime(2026, 10, 3, 12, 34, 56)
        self.assertEqual(self.mod.resolve_date(c, DATE, now=now), DATE + "T123456")

    def test_unchecked_hashes_parses_summary(self):
        self.assertEqual(
            self.mod.unchecked_hashes("0 hashes could not be checked"), 0
        )
        self.assertEqual(
            self.mod.unchecked_hashes("3 hashes could not be checked"), 3
        )
        self.assertEqual(self.mod.unchecked_hashes("no summary here"), 0)

    def test_run_backup_raises_when_nothing_was_checked(self):
        # rclone exits 0 even when it compared nothing; >0 unchecked hashes must fail.
        def run(argv, capture=False, env=None):
            return "3 hashes could not be checked"

        with self.assertRaises(self.mod.BackupError):
            self.mod.run_backup(
                cfg(self.mod, self.base, source=str(self.src)),
                DATE,
                run=run,
                out=lambda _s: None,
            )

    def test_marker_written_on_failure_and_removed_on_success(self):
        bad_cfg = cfg(self.mod, self.base, source=str(self.src))

        def failing(argv, capture=False, env=None):
            raise RuntimeError("boom")

        with self.assertRaises(RuntimeError):
            self.mod.run_backup(bad_cfg, DATE, run=failing, out=lambda _s: None)
        marker = self.mod.marker_path(bad_cfg)
        self.assertTrue(os.path.exists(marker))

        os.remove(marker)
        ran = []
        self.mod.run_backup(
            cfg(self.mod, self.base, offsite=False, source=str(self.src)),
            DATE,
            run=self.collector(ran),
            out=lambda _s: None,
        )
        self.assertFalse(os.path.exists(self.mod.marker_path(bad_cfg)))

    def test_success_removes_a_stale_marker(self):
        base_cfg = cfg(self.mod, self.base, offsite=False, source=str(self.src))
        os.makedirs(os.path.dirname(self.mod.marker_path(base_cfg)), exist_ok=True)
        with open(self.mod.marker_path(base_cfg), "w") as handle:
            handle.write("stale")
        ran = []
        self.mod.run_backup(
            base_cfg, DATE, run=self.collector(ran), out=lambda _s: None
        )
        self.assertFalse(os.path.exists(self.mod.marker_path(base_cfg)))

    def test_dry_run_executes_nothing_yet_prints_steps(self):
        ran = []
        buf = io.StringIO()
        self.mod.run_backup(
            cfg(self.mod, self.base),
            DATE,
            dry_run=True,
            run=self.collector(ran),
            out=buf.write,
        )
        self.assertEqual(ran, [])
        self.assertIn("rclone", buf.getvalue())
        self.assertIn("proton:media", buf.getvalue())

    def test_excludes_applied_to_both_copies_and_check(self):
        # A secret or regenerable cache inside the tree must never reach either
        # mirror; the check must use the same patterns or it flags them missing.
        c = cfg(self.mod, excludes=("**/.cache/**", "/rclone.conf"))
        steps = self.mod.build_steps(c, DATE)
        local = self.find(steps, "copy", "/var/backup/media/current")
        offsite = self.find(steps, "proton:media")
        for argv in (local, offsite, self.mod.build_check(c)):
            self.assertIn("--exclude", argv)
            self.assertIn("**/.cache/**", argv)
            self.assertIn("/rclone.conf", argv)

    def test_no_exclude_flags_by_default(self):
        for step in self.steps():
            self.assertNotIn("--exclude", step)

    def test_every_step_argv_has_no_secret(self):
        steps = self.steps() + [self.mod.build_check(cfg(self.mod))]
        for step in steps:
            self.assertNotIn("--password-file", step)
            self.assertNotIn("--password-command", step)

    def test_rclone_steps_carry_network_resilience_flags(self):
        # A transient Proton 5xx must be retried by rclone, not surfaced.
        for step in self.steps() + [self.mod.build_check(cfg(self.mod))]:
            for flag in ("--timeout", "--contimeout", "--retries", "--low-level-retries"):
                self.assertIn(flag, step)

    def test_rclone_steps_emit_machine_readable_progress(self):
        # The stall watchdog parses transferred bytes from the stats line, which
        # rclone hides at its default NOTICE log level unless raised.
        for step in self.steps() + [self.mod.build_check(cfg(self.mod))]:
            self.assertIn("--stats-one-line", step)
            self.assertIn("--stats", step)
            self.assertEqual(step[step.index("--stats-log-level") + 1], "NOTICE")

    def test_transferred_bytes_parses_rclone_stats(self):
        self.assertEqual(
            self.mod.transferred_bytes(
                "Transferred:   1.234 GiB / 5.678 GiB, 22%, 10 MiB/s, ETA 5m"
            ),
            int(1.234 * 1024**3),
        )
        self.assertIsNone(self.mod.transferred_bytes("no stats here"))

    def test_progress_only_counts_new_bytes_as_liveness(self):
        # A wedged transfer keeps printing stats; identical counts are not progress.
        clock = [0.0]
        progress = self.mod.Progress(60, clock=lambda: clock[0])
        progress.note("Transferred:   1.000 GiB / 2.000 GiB, 50%")
        clock[0] = 50
        self.assertFalse(progress.stalled())
        progress.note("Transferred:   1.000 GiB / 2.000 GiB, 50%")  # unchanged
        clock[0] = 61
        self.assertTrue(progress.stalled())

    def test_progress_resets_when_bytes_advance(self):
        clock = [0.0]
        progress = self.mod.Progress(60, clock=lambda: clock[0])
        progress.note("Transferred:   1.000 GiB / 2.000 GiB, 50%")
        clock[0] = 50
        progress.note("Transferred:   1.500 GiB / 2.000 GiB, 75%")
        self.assertFalse(progress.stalled())

    def test_parse_duration_units(self):
        self.assertEqual(self.mod.parse_duration("45"), 45)
        self.assertEqual(self.mod.parse_duration("30m"), 1800)
        self.assertEqual(self.mod.parse_duration("2h"), 7200)
        self.assertEqual(self.mod.parse_duration("1d"), 86400)
        for bad in ("soon", "", "5x"):
            with self.assertRaises(ValueError):
                self.mod.parse_duration(bad)

    def _run_streaming(self, lines, stall_timeout=60, attempts=1, timeout_after=None):
        proc = FakeProc(lines)
        clock = [0.0]
        calls = []

        def popen(argv, **kwargs):
            calls.append(argv)
            return proc

        def ready(fds, w, x, timeout):
            clock[0] += 31
            if timeout_after is not None and len(calls) > timeout_after:
                return ([], [], [])
            return (["ready"], [], [])

        result = self.mod.run_streaming(
            ["rclone", "copy"],
            stall_timeout=stall_timeout,
            attempts=attempts,
            popen=popen,
            ready=ready,
            clock=lambda: clock[0],
            out=lambda _line: None,
        )
        return result, proc, calls

    def test_run_streaming_relays_output_on_success(self):
        result, proc, _ = self._run_streaming(
            ["Transferred:   1.000 GiB / 2.000 GiB, 50%"]
        )
        self.assertIn("Transferred", result)
        self.assertFalse(proc.killed)

    def test_run_streaming_kills_a_silent_transfer(self):
        # ready returns nothing and the clock runs past the window: kill it.
        with self.assertRaises(self.mod.StalledError):
            self._run_streaming(["Transferred:   1.000 GiB / 2.000 GiB"], timeout_after=0)

    def test_run_streaming_retries_a_stall_then_gives_up(self):
        calls = []
        clock = [0.0]

        def popen(argv, **kwargs):
            calls.append(argv)
            return FakeProc([])

        def ready(fds, w, x, timeout):
            clock[0] += 61
            return ([], [], [])

        with self.assertRaises(self.mod.StalledError):
            self.mod.run_streaming(
                ["rclone", "copy"],
                stall_timeout=60,
                attempts=3,
                popen=popen,
                ready=ready,
                clock=lambda: clock[0],
                out=lambda _line: None,
            )
        # copy is resumable, so every retry re-runs the same argv
        self.assertEqual(calls, [["rclone", "copy"]] * 3)

    def test_plain_run_captures_and_propagates_failure(self):
        import sys

        out = self.mod._plain_run(
            [sys.executable, "-c", "print('hello')"], capture=True
        )
        self.assertIn("hello", out)
        with self.assertRaises(self.mod.subprocess.CalledProcessError):
            self.mod._plain_run(
                [sys.executable, "-c", "raise SystemExit(3)"], capture=True
            )

    def test_stall_timeout_defaults_to_zero_in_dataset(self):
        self.assertEqual(cfg(self.mod).stall_timeout, 0)


if __name__ == "__main__":
    unittest.main()
