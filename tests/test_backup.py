import importlib.util
import io
import json
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


class _Closable:
    def close(self):
        pass


class FakeProc:
    """Minimal subprocess.Popen stand-in for run_streaming tests."""

    def __init__(self):
        self.stdout = _Closable()
        self.killed = False
        self.returncode = 0

    def wait(self):
        return self.returncode

    def kill(self):
        self.killed = True
        self.returncode = -9


def cfg(
    module,
    base="/var/backup",
    offsite=True,
    pre_backup=None,
    source="/var/lib/media",
    excludes=(),
    timeout=None,
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
        timeout=(
            timeout if timeout is not None else module.DEFAULT_STEP_TIMEOUT
        ),
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
        # The offsite copy reports a change so the scoped check actually runs.
        def run(argv, capture=False, env=None):
            if "copy" in argv and "proton:media" in argv:
                return json.dumps({"msg": "Copied (new)", "object": "one.bin"})
            return "3 hashes could not be checked"

        with self.assertRaises(self.mod.BackupError):
            self.mod.run_backup(
                cfg(self.mod, self.base, source=str(self.src)),
                DATE,
                run=run,
                lock=False,
                out=lambda _s: None,
            )

    def test_run_backup_raises_when_check_verified_nothing(self):
        # Over-broad excludes can empty the mirror; rclone then verifies 0 files
        # (Checks: 0) and still exits 0, so the count itself must fail the run.
        def run(argv, capture=False, env=None):
            if "copy" in argv and "proton:media" in argv:
                return json.dumps({"msg": "Copied (new)", "object": "one.bin"})
            return "Checks:                 0 / 0,  -"

        with self.assertRaises(self.mod.BackupError):
            self.mod.run_backup(
                cfg(self.mod, self.base, source=str(self.src)),
                DATE,
                run=run,
                lock=False,
                out=lambda _s: None,
            )

    def test_run_backup_succeeds_when_check_output_starts_at_zero(self):
        # Regression: a healthy check whose first stats block is "0 / N" must not
        # be mistaken for an empty mirror — the final "75 / 75" is the verdict.
        def run(argv, capture=False, env=None):
            if "copy" in argv and "proton:media" in argv:
                return json.dumps({"msg": "Copied (new)", "object": "one.bin"})
            return "\n".join(
                [
                    "Checks:                 0 / 8,   0%",
                    "Checks:                75 / 75, 100%",
                    "0 differences found",
                ]
            )

        # No BackupError: the run completes and clears any failure marker.
        self.mod.run_backup(
            cfg(self.mod, self.base, source=str(self.src)),
            DATE,
            run=run,
            lock=False,
            out=lambda _s: None,
        )
        self.assertFalse(os.path.exists(self.mod.marker_path(
            cfg(self.mod, self.base, source=str(self.src))
        )))

    def test_marker_written_on_failure_and_removed_on_success(self):
        bad_cfg = cfg(self.mod, self.base, source=str(self.src))

        def failing(argv, capture=False, env=None):
            raise RuntimeError("boom")

        with self.assertRaises(RuntimeError):
            self.mod.run_backup(
                bad_cfg, DATE, run=failing, lock=False, out=lambda _s: None
            )
        marker = self.mod.marker_path(bad_cfg)
        self.assertTrue(os.path.exists(marker))

        os.remove(marker)
        ran = []
        self.mod.run_backup(
            cfg(self.mod, self.base, offsite=False, source=str(self.src)),
            DATE,
            run=self.collector(ran),
            lock=False,
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
            base_cfg, DATE, run=self.collector(ran), lock=False, out=lambda _s: None
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
        c = cfg(self.mod, excludes=("/.cache/**", "**/.cache/**", "/rclone.conf"))
        steps = self.mod.build_steps(c, DATE)
        local = self.find(steps, "copy", "/var/backup/media/current")
        offsite = self.find(steps, "proton:media")
        for argv in (local, offsite, self.mod.build_check(c)):
            self.assertIn("--exclude", argv)
            self.assertIn("/.cache/**", argv)
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
        # --stats-one-line strips the Transferred:/Checks: labels the watchdog
        # needs; the multi-line block keeps them, at NOTICE so they surface.
        for step in self.steps() + [self.mod.build_check(cfg(self.mod))]:
            self.assertIn("--stats", step)
            self.assertNotIn("--stats-one-line", step)
            self.assertEqual(step[step.index("--stats-log-level") + 1], "NOTICE")

    def test_transferred_bytes_parses_rclone_stats(self):
        self.assertEqual(
            self.mod.transferred_bytes(
                "Transferred:   \t1.234 GiB / 5.678 GiB, 22%, 10 MiB/s, ETA 5m"
            ),
            int(1.234 * 1024**3),
        )
        self.assertIsNone(self.mod.transferred_bytes("no stats here"))

    def test_checked_count_parses_rclone_stats(self):
        self.assertEqual(self.mod.checked_count("Checks:                12 / 40,  30%"), 12)
        self.assertIsNone(self.mod.checked_count("no checks here"))

    # --- incremental offsite verification ---------------------------------

    def test_copied_paths_parses_new_replaced_and_ignores_metadata(self):
        lines = [
            json.dumps({"level": "info", "msg": "Copied (new)", "object": "a.jpg"}),
            json.dumps(
                {
                    "level": "info",
                    "msg": "Copied (replaced existing)",
                    "object": "b/c.jpg",
                }
            ),
            # Metadata-only: not a content change, must not enter the verify set.
            json.dumps(
                {"msg": "Updated modification time in destination", "object": "d.jpg"}
            ),
            json.dumps({"msg": "There was nothing to transfer"}),
            json.dumps({"msg": "Deleted", "object": "gone.jpg"}),
            "not json at all",
            '{"msg": "Copied (new)", "object":',  # truncated JSON
            "[]",  # valid JSON, not an object
            "42",
            json.dumps({"msg": "Copied (new)"}),  # no object key
        ]
        self.assertEqual(self.mod.copied_paths(lines), ["a.jpg", "b/c.jpg"])

    def test_copied_paths_is_spoof_safe(self):
        # A filename that itself looks like a copied message lands in `object`,
        # never in `msg`, so only the msg field decides inclusion.
        line = json.dumps({"msg": "Copied (new)", "object": "evil Copied (new).jpg"})
        self.assertEqual(self.mod.copied_paths([line]), ["evil Copied (new).jpg"])
        spoof = json.dumps({"msg": "Some other op", "object": "Copied (new)"})
        self.assertEqual(self.mod.copied_paths([spoof]), [])

    def test_copied_paths_ignores_a_non_string_object(self):
        line = json.dumps({"msg": "Copied (new)", "object": 5})
        self.assertEqual(self.mod.copied_paths([line]), [])

    def test_only_the_offsite_copy_uses_json_logging(self):
        # Only the offsite copy's output is parsed for changed paths, so only it
        # needs JSON logging; the local copy and the check stay plain text.
        steps = self.steps()
        local = self.find(steps, "copy", "/var/lib/media")
        offsite = self.find(steps, "proton:media")
        self.assertNotIn("--use-json-log", local)
        self.assertIn("--use-json-log", offsite)
        self.assertEqual(offsite[offsite.index("--log-level") + 1], "INFO")
        self.assertNotIn("--use-json-log", self.mod.build_check(cfg(self.mod)))

    def test_stats_regexes_parse_json_log_lines(self):
        # rclone escapes the tab between "Transferred:" and the counter as \t in
        # JSON, so the bytes regex must tolerate it; the Checks label is plain.
        line = json.dumps(
            {
                "level": "notice",
                "msg": "\nTransferred:   \t          6 B / 6 B, 100%, 0 B/s, ETA -\n"
                "Checks:                 3 / 3, 100%\n",
            }
        )
        self.assertEqual(self.mod.transferred_bytes(line), 6)
        self.assertEqual(self.mod.checked_count(line), 3)

    def test_build_check_adds_files_from_when_given(self):
        check = self.mod.build_check(cfg(self.mod), files_from="/tmp/changed.txt")
        self.assertIn("--checksum", check)
        self.assertIn("--one-way", check)
        self.assertEqual(check[check.index("--files-from") + 1], "/tmp/changed.txt")

    def test_build_check_without_files_from_walks_the_whole_tree(self):
        self.assertNotIn("--files-from", self.mod.build_check(cfg(self.mod)))

    def test_run_backup_skips_check_when_the_offsite_copy_changed_nothing(self):
        ran = []
        messages = []

        def run(argv, capture=False, env=None):
            ran.append(argv)
            # A no-change copy logs only "nothing to transfer", no Copied lines.
            if "copy" in argv and "proton:media" in argv:
                return json.dumps({"msg": "There was nothing to transfer"})
            return ""

        self.mod.run_backup(
            cfg(self.mod, self.base, source=str(self.src)),
            DATE,
            run=run,
            lock=False,
            out=messages.append,
        )
        self.assertFalse(any("check" in step for step in ran))
        self.assertTrue(any("skipping verification" in m for m in messages))

    def test_run_backup_checks_only_the_changed_paths(self):
        ran = []

        def run(argv, capture=False, env=None):
            ran.append(argv)
            if "copy" in argv and "proton:media" in argv:
                return json.dumps({"msg": "Copied (new)", "object": "one.bin"})
            if "check" in argv:
                return "Checks:                 1 / 1, 100%\n0 differences found"
            return ""

        self.mod.run_backup(
            cfg(self.mod, self.base, source=str(self.src)),
            DATE,
            run=run,
            lock=False,
            out=lambda _s: None,
        )
        check = next(step for step in ran if "check" in step)
        self.assertIn("--files-from", check)
        # The temp file is removed on the way out.
        self.assertFalse(os.path.exists(check[check.index("--files-from") + 1]))

    def test_run_backup_writes_changed_paths_to_the_files_from_file(self):
        captured = {}

        def run(argv, capture=False, env=None):
            if "copy" in argv and "proton:media" in argv:
                return "\n".join(
                    [
                        json.dumps({"msg": "Copied (new)", "object": "a/one.bin"}),
                        json.dumps(
                            {
                                "msg": "Copied (replaced existing)",
                                "object": "two.bin",
                            }
                        ),
                    ]
                )
            if "check" in argv:
                with open(argv[argv.index("--files-from") + 1]) as handle:
                    captured["paths"] = handle.read().split()
                return "Checks: 2 / 2, 100%\n0 differences found"
            return ""

        self.mod.run_backup(
            cfg(self.mod, self.base, source=str(self.src)),
            DATE,
            run=run,
            lock=False,
            out=lambda _s: None,
        )
        self.assertEqual(captured["paths"], ["a/one.bin", "two.bin"])

    def test_run_backup_removes_the_files_from_file_on_check_failure(self):
        paths = {}

        def run(argv, capture=False, env=None):
            if "copy" in argv and "proton:media" in argv:
                return json.dumps({"msg": "Copied (new)", "object": "one.bin"})
            if "check" in argv:
                paths["file"] = argv[argv.index("--files-from") + 1]
                return "3 hashes could not be checked"
            return ""

        with self.assertRaises(self.mod.BackupError):
            self.mod.run_backup(
                cfg(self.mod, self.base, source=str(self.src)),
                DATE,
                run=run,
                lock=False,
                out=lambda _s: None,
            )
        # The temp file is cleaned up even when the check fails.
        self.assertFalse(os.path.exists(paths["file"]))

    def test_run_backup_full_check_walks_the_tree_and_is_never_skipped(self):
        ran = []

        def run(argv, capture=False, env=None):
            ran.append(argv)
            # No Copied lines at all: a change-free run.
            if "check" in argv:
                return "Checks:                 1 / 1, 100%\n0 differences found"
            return ""

        self.mod.run_backup(
            cfg(self.mod, self.base, source=str(self.src)),
            DATE,
            run=run,
            lock=False,
            out=lambda _s: None,
            full_check=True,
        )
        check = next(step for step in ran if "check" in step)
        self.assertNotIn("--files-from", check)

    def test_run_backup_full_check_ignores_the_changed_set(self):
        ran = []

        def run(argv, capture=False, env=None):
            ran.append(argv)
            if "copy" in argv and "proton:media" in argv:
                return json.dumps({"msg": "Copied (new)", "object": "one.bin"})
            if "check" in argv:
                return "Checks:                 1 / 1, 100%\n0 differences found"
            return ""

        self.mod.run_backup(
            cfg(self.mod, self.base, source=str(self.src)),
            DATE,
            run=run,
            lock=False,
            out=lambda _s: None,
            full_check=True,
        )
        check = next(step for step in ran if "check" in step)
        self.assertNotIn("--files-from", check)

    def test_cli_full_check_flag_forces_the_whole_tree_check(self):
        import contextlib

        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = self.mod.main(
                [
                    "--name",
                    "media",
                    "--source",
                    "/x",
                    "--backup-root",
                    "/y",
                    "--rclone-config",
                    "/z",
                    "--offsite",
                    "--dry-run",
                    "--full-check",
                ]
            )
        self.assertEqual(rc, 0)
        self.assertIn("check", buf.getvalue())
        self.assertNotIn("--files-from", buf.getvalue())

    def test_copied_paths_accepts_to_suffix_and_other_variants(self):
        # Older rclone appends " to: <dest>"; some backends prefix or wrap the
        # action. All are content writes and must enter the verify set.
        for msg in (
            "Copied (new) to: proton:media/a.jpg",
            "Copied (replaced existing) to: proton:media/b.jpg",
            "Multi-thread Copied (new)",
        ):
            line = json.dumps({"msg": msg, "object": "x.jpg"})
            self.assertEqual(self.mod.copied_paths([line]), ["x.jpg"])

    def test_transferred_bytes_last_reads_the_final_stats_block(self):
        text = "\n".join(
            [
                "Transferred:   0 B / 0 B, -, 0 B/s, ETA -",
                "Transferred:   1.000 GiB / 2.000 GiB, 50%",
            ]
        )
        self.assertEqual(self.mod.transferred_bytes_last(text), 1024**3)
        self.assertIsNone(self.mod.transferred_bytes_last("nothing here"))

    def test_run_backup_fails_when_bytes_transferred_without_recorded_paths(self):
        # If the offsite copy moved bytes but no copied path could be parsed
        # (e.g. rclone changed its message format), fail rather than skip: an
        # unverified mirror must never look like a green run.
        def run(argv, capture=False, env=None):
            if "copy" in argv and "proton:media" in argv:
                return json.dumps(
                    {
                        "level": "notice",
                        "msg": "Transferred:   \t          3 B / 3 B, 100%",
                    }
                )
            return ""

        with self.assertRaises(self.mod.BackupError):
            self.mod.run_backup(
                cfg(self.mod, self.base, source=str(self.src)),
                DATE,
                run=run,
                lock=False,
                out=lambda _s: None,
            )

    def test_run_backup_keeps_the_marker_when_the_check_is_skipped(self):
        # A skipped check must not erase a prior failure's evidence: an unchanged
        # mirror is not a verified one.
        c = cfg(self.mod, self.base, source=str(self.src))
        os.makedirs(os.path.dirname(self.mod.marker_path(c)), exist_ok=True)
        with open(self.mod.marker_path(c), "w") as handle:
            handle.write("prior failure")

        def run(argv, capture=False, env=None):
            if "copy" in argv and "proton:media" in argv:
                return json.dumps({"msg": "There was nothing to transfer"})
            return ""

        self.mod.run_backup(c, DATE, run=run, lock=False, out=lambda _s: None)
        self.assertTrue(os.path.exists(self.mod.marker_path(c)))

    def test_checked_count_takes_the_final_total_from_a_whole_run(self):
        # A captured check run is a whole log: rclone's opening stats block prints
        # "Checks: 0 / N" and the counter climbs to the total. Parsing the first
        # match reads the opening 0 and falsely fails a healthy mirror.
        output = "\n".join(
            [
                "Checks:                 0 / 8,   0%",
                "Checks:                53 / 61, 87%",
                "Checks:                75 / 75, 100%",
            ]
        )
        self.assertEqual(self.mod.checked_count(output), 75)

    def test_progress_counts_checked_files_as_liveness(self):
        # A pure `rclone check` moves no bytes but advances Checks:; without that
        # a healthy long verification would look like a stall.
        clock = [0.0]
        progress = self.mod.Progress(60, clock=lambda: clock[0])
        progress.note("Checks:                 5 / 40,  12%")
        clock[0] = 50
        progress.note("Checks:                10 / 40,  25%")
        self.assertFalse(progress.stalled())

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

    def _run_streaming(self, lines, stall_timeout=60, attempts=1, idle_after=None):
        chunks = [f"{line}\n".encode() for line in lines] + [b""]
        procs = []
        clock = [0.0]

        def popen(argv, **kwargs):
            proc = FakeProc()
            procs.append(proc)
            return proc

        def ready(fds, w, x, timeout):
            clock[0] += 31
            if idle_after is not None and len(procs) > idle_after:
                return ([], [], [])
            return ([True], [], [])

        def read(fd, size):
            return chunks.pop(0) if chunks else b""

        result = self.mod.run_streaming(
            ["rclone", "copy"],
            stall_timeout=stall_timeout,
            attempts=attempts,
            popen=popen,
            ready=ready,
            read=read,
            clock=lambda: clock[0],
            out=lambda _line: None,
            capture=True,
        )
        return result, procs

    def test_run_streaming_relays_output_on_success(self):
        result, procs = self._run_streaming(
            ["Transferred:   1.000 GiB / 2.000 GiB, 50%"]
        )
        self.assertIn("Transferred", result)
        self.assertFalse(procs[0].killed)

    def test_run_streaming_kills_a_transfer_that_keeps_printing_but_stalls(self):
        # The real failure keeps emitting identical stats; progress must be
        # sampled on every line, not only when the pipe goes quiet.
        with self.assertRaises(self.mod.StalledError):
            self._run_streaming(["Transferred:   1.000 GiB / 2.000 GiB, 50%"] * 4)

    def test_run_streaming_kills_a_silent_transfer(self):
        # ready returns nothing and the clock runs past the window: kill it.
        with self.assertRaises(self.mod.StalledError):
            self._run_streaming([], idle_after=0)

    def test_run_streaming_retries_a_stall_then_gives_up(self):
        calls = []
        clock = [0.0]

        def popen(argv, **kwargs):
            calls.append(argv)
            return FakeProc()

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

    # --- F5: stall timeout vs stats cadence -------------------------------

    def test_validate_stall_timeout_rejects_window_below_two_stats_intervals(self):
        # The watchdog can only see progress when a stats line lands (every 30s),
        # so a window under 2 intervals could kill a healthy transfer.
        with self.assertRaises(self.mod.BackupError):
            self.mod.validate_stall_timeout(59)
        self.assertEqual(self.mod.validate_stall_timeout(60), 60)
        self.assertEqual(self.mod.validate_stall_timeout(0), 0)  # disables it

    # --- F19: --date path-escape validation -------------------------------

    def test_validate_date_rejects_path_escapes(self):
        for bad in ("../etc", "2026/10/03", "a\\b", "..", "", ".", "a/../b"):
            with self.assertRaises(self.mod.BackupError):
                self.mod.validate_date(bad)
        for good in ("2026-10-03", "2026-10-03T123456", "run_1.2-3"):
            self.assertEqual(self.mod.validate_date(good), good)

    def test_validate_name_rejects_path_escapes(self):
        # The name is both a local path component and the remote folder, so it
        # must not carry separators or traverse out of the backup tree.
        for bad in ("..", "a/b", "", ".", "-leading", "a\\b"):
            with self.assertRaises(self.mod.BackupError):
                self.mod.validate_name(bad)
        self.assertEqual(self.mod.validate_name("Photos"), "Photos")

    # --- F15: collision-free version stamp --------------------------------

    def test_resolve_date_disambiguates_two_runs_in_the_same_second(self):
        import datetime

        c = cfg(self.mod, self.base)
        os.makedirs(self.mod.versions_dir(c, DATE))
        now = datetime.datetime(2026, 10, 3, 12, 34, 56)
        first = self.mod.resolve_date(c, DATE, now=now)
        self.assertEqual(first, DATE + "T123456")
        os.makedirs(self.mod.versions_dir(c, first))
        second = self.mod.resolve_date(c, DATE, now=now)
        self.assertNotEqual(second, first)
        self.assertFalse(os.path.exists(self.mod.versions_dir(c, second)))

    # --- F3: marker write must not mask the real error --------------------

    def test_marker_write_does_not_mask_the_underlying_error(self):
        # require_source runs before any makedirs, so the dataset dir is missing
        # on a fresh disk; writing the marker must not raise FileNotFoundError
        # and replace the real BackupError.
        missing = str(Path(self.base) / "missing-source")
        c = cfg(self.mod, self.base, source=missing)
        with self.assertRaises(self.mod.BackupError):
            self.mod.run_backup(
                c, DATE, run=self.collector([]), lock=False, out=lambda _s: None
            )
        self.assertTrue(os.path.exists(self.mod.marker_path(c)))

    # --- F7: host-wide lock ----------------------------------------------

    def test_acquire_lock_creates_0600_and_releases_on_close(self):
        path = str(Path(self.base) / "lock")
        first = self.mod.acquire_lock(path=path, out=lambda _l: None)
        self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
        # flock locks are per open file description, so a second open conflicts
        # even inside one process.
        fd = os.open(path, os.O_WRONLY)
        with self.assertRaises(BlockingIOError):
            self.mod.fcntl.flock(fd, self.mod.fcntl.LOCK_EX | self.mod.fcntl.LOCK_NB)
        first.close()
        self.mod.fcntl.flock(fd, self.mod.fcntl.LOCK_EX | self.mod.fcntl.LOCK_NB)
        os.close(fd)

    def test_acquire_lock_reports_waiting_when_busy(self):
        path = str(Path(self.base) / "lock2")
        real = self.mod.fcntl.flock
        state = {"calls": 0}
        messages = []

        def busy_once(handle, op):
            state["calls"] += 1
            if state["calls"] == 1:
                raise BlockingIOError("busy")

        self.mod.fcntl.flock = busy_once
        try:
            handle = self.mod.acquire_lock(path=path, out=messages.append)
        finally:
            self.mod.fcntl.flock = real
        handle.close()
        self.assertTrue(any("waiting for lock" in m for m in messages))
        self.assertEqual(state["calls"], 2)

    # --- N2 / F4: runner wiring and independent step timeout --------------

    def test_make_runner_routes_rclone_streamed_and_plain_steps(self):
        seen = []
        self.mod.run_streaming = (
            lambda argv, **kw: seen.append(("stream", argv, kw.get("stall_timeout")))
        )
        self.mod._plain_run = (
            lambda argv, capture=False, env=None, timeout=0: seen.append(
                ("plain", argv, timeout)
            )
        )
        run = self.mod.make_runner(120, plain_timeout=7)
        run(["rclone", "copy"])
        run(["/bin/true"])
        self.assertEqual(seen[0], ("stream", ["rclone", "copy"], 120))
        self.assertEqual(seen[1], ("plain", ["/bin/true"], 7))

    def test_plain_runner_bounded_even_when_watchdog_disabled(self):
        import sys

        # stall_timeout=0 disables the rclone watchdog, but a non-rclone step
        # must still be bounded or a hung dump would hold the lock forever.
        run = self.mod.make_runner(0, plain_timeout=0.5)
        with self.assertRaises(self.mod.subprocess.TimeoutExpired):
            run([sys.executable, "-c", "import time; time.sleep(5)"])

    def test_plain_run_honors_its_timeout(self):
        import sys

        with self.assertRaises(self.mod.subprocess.TimeoutExpired):
            self.mod._plain_run(
                [sys.executable, "-c", "import time; time.sleep(5)"], timeout=0.5
            )

    def test_run_backup_kills_hung_pre_backup_with_watchdog_disabled(self):
        import sys

        script = Path(self.base) / "slow-pre"
        script.write_text(f"#!/bin/sh\nexec {sys.executable} -c 'import time; time.sleep(5)'\n")
        script.chmod(0o755)
        c = cfg(
            self.mod,
            self.base,
            source=str(self.src),
            pre_backup=str(script),
            timeout=1,
        )
        c = c._replace(stall_timeout=0)
        with self.assertRaises(self.mod.subprocess.TimeoutExpired):
            self.mod.run_backup(c, DATE, lock=False, out=lambda _s: None)

    # --- F14: stall checks on newline-free streams ------------------------

    def test_run_streaming_stall_checks_a_newline_free_stream(self):
        clock = [0.0]

        def popen(argv, **kwargs):
            return FakeProc()

        def ready(fds, w, x, timeout):
            return ([True], [], [])

        def read(fd, size):
            clock[0] += 31  # each read advances time; no newline ever arrives
            return b"xxxxxxxxxx"

        with self.assertRaises(self.mod.StalledError):
            self.mod.run_streaming(
                ["rclone", "copy"],
                stall_timeout=60,
                attempts=1,
                popen=popen,
                ready=ready,
                read=read,
                clock=lambda: clock[0],
                out=lambda _line: None,
            )

    def test_run_streaming_flushes_an_oversized_partial_buffer(self):
        out = []
        reads = iter([b"z" * (self.mod._MAX_PARTIAL_LINE + 1), b""])

        def popen(argv, **kwargs):
            return FakeProc()

        def ready(fds, w, x, timeout):
            return ([True], [], [])

        def read(fd, size):
            return next(reads)

        result = self.mod.run_streaming(
            ["rclone", "copy"],
            stall_timeout=60,
            attempts=1,
            popen=popen,
            ready=ready,
            read=read,
            clock=lambda: 0.0,
            out=out.append,
            capture=True,
        )
        # The oversized partial line was flushed instead of accumulating.
        self.assertTrue(out)
        self.assertIn("z", result)

    def test_run_streaming_raises_on_nonzero_exit(self):
        # A non-zero rclone exit must surface, not be swallowed as empty output.
        def popen(argv, **kwargs):
            proc = FakeProc()
            proc.returncode = 2
            return proc

        def read(fd, size):
            return b""

        with self.assertRaises(self.mod.subprocess.CalledProcessError):
            self.mod.run_streaming(
                ["rclone", "check"],
                popen=popen,
                read=read,
                out=lambda _line: None,
            )

    def test_run_streaming_strips_control_characters_from_out(self):
        # Source filenames are attacker-influenceable; ANSI escapes and other C0
        # controls must not reach the journal.
        seen = []
        chunks = [b"evil\x1b[31mname\x07.bin\n", b""]

        def popen(argv, **kwargs):
            return FakeProc()

        def read(fd, size):
            return chunks.pop(0) if chunks else b""

        self.mod.run_streaming(
            ["rclone", "copy"],
            popen=popen,
            read=read,
            out=seen.append,
        )
        self.assertEqual(seen, ["evil[31mname.bin"])

    def test_run_streaming_retries_a_stall_then_succeeds(self):
        procs = []
        clock = [0.0]

        def popen(argv, **kwargs):
            procs.append(FakeProc())
            return procs[-1]

        def ready(fds, w, x, timeout):
            if len(procs) == 1:
                clock[0] += 61  # first attempt stalls
                return ([], [], [])
            return ([True], [], [])

        def read(fd, size):
            return b""

        result = self.mod.run_streaming(
            ["rclone", "copy"],
            stall_timeout=60,
            attempts=3,
            popen=popen,
            ready=ready,
            read=read,
            clock=lambda: clock[0],
            out=lambda _line: None,
        )
        # First attempt killed, retry (resumable copy) finished cleanly.
        self.assertTrue(procs[0].killed)
        self.assertEqual(len(procs), 2)
        self.assertFalse(procs[1].killed)
        self.assertEqual(result, "")


if __name__ == "__main__":
    unittest.main()
