import importlib.util
import io
import tempfile
import unittest
from pathlib import Path


def load_module():
    path = Path(__file__).parents[1] / "modules/features/immich/immich_backup.py"
    spec = importlib.util.spec_from_file_location("immich_backup", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def cfg(module, base="/var/backup"):
    return module.Repo(
        repo=f"{base}/immich/restic",
        library="/var/lib/immich/library",
        dump_file=f"{base}/immich/dump/immich.sql",
        password_file="/var/lib/immich/restic.pass",
        rclone_config="/var/lib/immich/rclone.conf",
        remote="proton",
        remote_path="immich/restic",
        keep_daily="14",
        keep_weekly="8",
        keep_monthly="12",
    )


class ImmichBackupTests(unittest.TestCase):
    def setUp(self):
        self.mod = load_module()
        self.tmp = tempfile.TemporaryDirectory()
        self.base = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def steps(self, initialized=True):
        return self.mod.build_steps(cfg(self.mod), initialized)

    def find(self, *needle):
        for step in self.steps():
            if all(n in step for n in needle):
                return step
        self.fail(f"no step containing {needle}")

    def test_pg_dump_writes_to_file_and_names_db(self):
        dump = self.find("pg_dump")
        self.assertIn("--file", dump)
        self.assertIn("/var/backup/immich/dump/immich.sql", dump)
        self.assertEqual(dump[-1], "immich")

    def test_snapshot_covers_library_and_dump(self):
        backup = self.find("restic", "backup")
        self.assertIn("/var/lib/immich/library", backup)
        self.assertIn("/var/backup/immich/dump/immich.sql", backup)

    def test_retention_keeps_a_tail(self):
        forget = self.find("restic", "forget")
        self.assertIn("--keep-daily", forget)
        self.assertIn("--keep-weekly", forget)
        self.assertIn("--keep-monthly", forget)
        self.assertIn("--prune", forget)

    def test_integrity_check_runs(self):
        check = self.find("restic", "check")
        self.assertIn("/var/lib/immich/restic.pass", check)

    def test_mirror_is_append_only_copy_not_sync(self):
        # Regression guard: `sync` would delete the offsite copy when a local
        # file disappears; the whole point is that deletions never propagate.
        rclone = self.find("rclone", "copy")
        self.assertNotIn("sync", rclone)
        self.assertNotIn("--delete-during", rclone)
        self.assertNotIn("--delete", rclone)
        self.assertIn("proton:immich/restic", rclone)
        self.assertIn("--config", rclone)

    def test_password_never_on_command_line(self):
        for step in self.steps():
            self.assertNotIn("--password", step)

    def test_init_only_when_repo_missing(self):
        with_init = self.mod.build_steps(cfg(self.mod), repo_initialized=False)
        self.assertIn("init", with_init[0])
        without = self.mod.build_steps(cfg(self.mod), repo_initialized=True)
        self.assertFalse(any("init" in step for step in without))

    def test_dry_run_executes_nothing(self):
        ran = []
        buf = io.StringIO()
        self.mod.run_backup(
            cfg(self.mod, self.base), dry_run=True, run=ran.append, out=buf.write
        )
        self.assertEqual(ran, [])
        self.assertIn("pg_dump", buf.getvalue())
        self.assertIn("rclone", buf.getvalue())

    def test_run_executes_every_step_in_order(self):
        ran = []
        self.mod.run_backup(
            cfg(self.mod, self.base),
            dry_run=False,
            run=ran.append,
            out=lambda _s: None,
        )
        verbs = [step[0] for step in ran]
        self.assertEqual(verbs[0], "restic")  # repo probe
        self.assertIn("pg_dump", verbs)
        self.assertEqual(verbs[-1], "rclone")
        # last restic call is the integrity check, after all writes
        self.assertIn("check", ran[-2])


if __name__ == "__main__":
    unittest.main()
