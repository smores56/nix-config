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


def cfg(module, base="/var/backup", offsite=True, pre_backup=None, source="/var/lib/media"):
    return module.Dataset(
        name="media",
        source=source,
        backup_root=base,
        offsite=offsite,
        remote="proton",
        rclone_config="/var/lib/backup/rclone.conf",
        pre_backup=pre_backup,
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

    def test_pre_backup_runs_first_with_snippet(self):
        steps = self.steps(pre_backup="echo seed >/dev/null")
        self.assertEqual(steps[0], ["sh", "-c", "echo seed >/dev/null"])

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
        class Result:
            stdout = "3 hashes could not be checked"

        def run(argv, capture=False, env=None):
            return Result()

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

    def test_every_step_argv_has_no_secret(self):
        steps = self.steps() + [self.mod.build_check(cfg(self.mod))]
        for step in steps:
            self.assertNotIn("--password-file", step)
            self.assertNotIn("--password-command", step)


if __name__ == "__main__":
    unittest.main()
