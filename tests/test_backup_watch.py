import importlib.util
import os
import stat
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parent.parent / "modules/features/backup/backup_watch.py"


def load_module():
    spec = importlib.util.spec_from_file_location("backup_watch", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class DebouncerTests(unittest.TestCase):
    def setUp(self):
        self.mod = load_module()

    def test_waits_for_the_full_quiet_period(self):
        deb = self.mod.Debouncer(900)
        deb.note(now=1000)
        self.assertFalse(deb.take(now=1899))
        self.assertTrue(deb.take(now=1900))

    def test_an_event_restarts_the_quiet_period(self):
        deb = self.mod.Debouncer(900)
        deb.note(now=1000)
        deb.note(now=1500)
        self.assertFalse(deb.take(now=2000))
        self.assertTrue(deb.take(now=2400))

    def test_take_clears_the_batch(self):
        deb = self.mod.Debouncer(10)
        deb.note(now=0)
        self.assertTrue(deb.take(now=10))
        self.assertFalse(deb.take(now=20))

    def test_idle_debouncer_never_fires(self):
        self.assertFalse(self.mod.Debouncer(10).take(now=100))


class IgnoreTests(unittest.TestCase):
    def setUp(self):
        self.mod = load_module()
        self.source = "/var/lib/media/Photos"

    def ignored(self, path, ignores=()):
        return self.mod.is_ignored(path, self.source, ignores)

    def test_ordinary_media_is_accepted(self):
        self.assertFalse(self.ignored("/var/lib/media/Photos/2026/2026-10-18/a.jpg"))
        self.assertFalse(self.ignored("/var/lib/media/Photos/library/a.jpg"))

    def test_hidden_entries_are_ignored(self):
        self.assertTrue(self.ignored("/var/lib/media/Photos/.cache/x"))
        self.assertTrue(self.ignored("/var/lib/media/Photos/2026/.hidden.jpg"))
        self.assertTrue(self.ignored("/var/lib/media/Photos/.DS_Store"))

    def test_inflight_and_temp_files_are_ignored(self):
        for name in ("x.part", "x.partial", "x.tmp", "x.temp", "x.swp", "x.crdownload", "x.download", "x.aria2"):
            self.assertTrue(self.ignored(f"/var/lib/media/Photos/{name}"), name)

    def test_configured_components_are_ignored(self):
        ignores = ["thumbs", "encoded-video"]
        self.assertTrue(self.ignored("/var/lib/media/Photos/thumbs/2026/x.jpg", ignores))
        self.assertTrue(self.ignored("/var/lib/media/Photos/encoded-video/x.mp4", ignores))
        self.assertFalse(self.ignored("/var/lib/media/Photos/2026/x.jpg", ignores))

    def test_glob_patterns_can_be_used(self):
        self.assertTrue(self.ignored("/var/lib/media/Photos/@eaDir/x.jpg", ["@eaDir"]))
        self.assertTrue(self.ignored("/var/lib/media/Photos/x.jpg.tmp2", ["*.tmp2"]))

    def test_paths_outside_the_source_are_ignored(self):
        self.assertTrue(self.ignored("/var/lib/media/Videos/x.mp4"))
        self.assertTrue(self.ignored("/var/lib/media/Photos/../Videos/x.mp4"))


class QueueTests(unittest.TestCase):
    def setUp(self):
        self.mod = load_module()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def test_writes_a_private_request_file(self):
        path = self.mod.write_request(self.tmp.name)
        self.assertTrue(os.path.exists(path))
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
        self.assertEqual(os.path.dirname(path), self.tmp.name)

    def test_each_batch_gets_a_distinct_request(self):
        first = self.mod.write_request(self.tmp.name)
        second = self.mod.write_request(self.tmp.name)
        self.assertNotEqual(first, second)
        self.assertEqual(sorted(os.listdir(self.tmp.name)), sorted([os.path.basename(first), os.path.basename(second)]))

    def test_creates_the_queue_directory(self):
        queue = str(Path(self.tmp.name) / "nested")
        self.mod.write_request(queue)
        self.assertTrue(os.path.isdir(queue))


class RunLoopTests(unittest.TestCase):
    def setUp(self):
        self.mod = load_module()
        self.source = "/srv/media"

    def run_loop(self, events, debounce=900):
        now = [0.0]
        writes = []
        pending = list(events)

        def read_line(_timeout):
            item = pending.pop(0)
            if item is None:
                now[0] += 300
                return None
            return item

        with self.assertRaises(self.mod.WatcherExit):
            self.mod.run_loop(
                self.source,
                "/queue",
                debounce,
                (),
                read_line=read_line,
                clock=lambda: now[0],
                write=writes.append,
            )
        return writes

    def test_queues_one_request_after_the_quiet_period(self):
        # 900s debounce, three 300s timeouts after the event: due on the third.
        writes = self.run_loop(["/srv/media/a.jpg", None, None, None, ""])
        self.assertEqual(writes, ["/queue"])

    def test_ignored_events_never_queue(self):
        writes = self.run_loop(["/srv/media/.cache/x", None, None, None, ""])
        self.assertEqual(writes, [])

    def test_a_new_event_restarts_the_period(self):
        writes = self.run_loop(["/srv/media/a.jpg", None, "/srv/media/b.jpg", None, None, None, ""])
        self.assertEqual(writes, ["/queue"])

    def test_eof_is_an_exit(self):
        writes = self.run_loop([""])
        self.assertEqual(writes, [])


if __name__ == "__main__":
    unittest.main()
