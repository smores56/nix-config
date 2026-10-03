import importlib.util
import io
import os
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

JPEG = b"\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01" + b"\x00" * 8
PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 8
MP4 = b"\x00\x00\x00\x18ftypisom" + b"\x00" * 8


def load_module():
    path = Path(__file__).parents[1] / "modules/features/photobucket/photobucket.py"
    spec = importlib.util.spec_from_file_location("photobucket", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class PhotobucketTests(unittest.TestCase):
    def setUp(self):
        self.pb = load_module()
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / "root"
        self.root.mkdir()
        self._old_root = os.environ.get("PHOTOBUCKET_ROOT")
        os.environ["PHOTOBUCKET_ROOT"] = str(self.root)

    def tearDown(self):
        if self._old_root is None:
            os.environ.pop("PHOTOBUCKET_ROOT", None)
        else:
            os.environ["PHOTOBUCKET_ROOT"] = self._old_root
        self.tmp.cleanup()

    @staticmethod
    def write(path, content=b"", mtime=1_600_000_000):
        path = Path(path)
        data = content if isinstance(content, bytes) else content.encode()
        path.write_bytes(data)
        os.utime(path, (mtime, mtime))
        return str(path.resolve())

    def make_source(self, name="vacation photos!"):
        source = Path(self.tmp.name) / name
        source.mkdir()
        return source

    @staticmethod
    def ns(**kwargs):
        return type("Args", (), kwargs)()

    def session(self, name="s", source=None):
        session_path = self.root / name
        self.pb.write_session(str(session_path), source or str(self.root))
        return name, session_path

    # -- capture key --------------------------------------------------------

    def test_capture_key_priority_filename_beats_exif_beats_mtime(self):
        key = self.pb.capture_key(
            "/x/20190404_182256.jpg", exif="2001-01-01 00:00:00", mtime=1_600_000_000
        )
        self.assertTrue(key.startswith("2019-04-04T18:22:56"))
        # Unparseable filename -> EXIF wins over mtime.
        key = self.pb.capture_key(
            "/x/photo.jpg", exif="2002-02-02 03:04:05", mtime=1_600_000_000
        )
        self.assertTrue(key.startswith("2002-02-02T03:04:05"))
        # No filename date and no EXIF -> mtime.
        key = self.pb.capture_key("/x/photo.jpg", mtime="2003-03-03 00:00:00")
        self.assertTrue(key.startswith("2003-03-03"))
        # Regression: os.path.getmtime yields a float epoch, which must resolve.
        key = self.pb.capture_key("/x/photo.jpg", mtime=1_600_000_000.0)
        self.assertTrue(key.startswith("2020-09-13"), key)
        # Only a genuinely unresolvable file yields the empty key.
        self.assertEqual(self.pb.capture_key("/x/photo.jpg"), "")

    def test_parse_filename_date_variants(self):
        cases = {
            "20190404_182256.jpg": "2019-04-04T18:22:56",
            "20190404-182256.jpg": "2019-04-04T18:22:56",
            "IMG-20190404-WA0001.jpg": "2019-04-04T00:00:00",
            "20190505.jpg": "2019-05-05T00:00:00",
            "2019-06-07.png": "2019-06-07T00:00:00",
            "not-a-date.jpg": None,
        }
        for name, expected in cases.items():
            parsed = self.pb.parse_filename_date(name)
            if expected is None:
                self.assertIsNone(parsed, name)
            else:
                self.assertEqual(parsed.isoformat(), expected, name)
        # 13-digit epoch milliseconds, as the whole basename.
        epoch = self.pb.parse_filename_date("1463557096611.jpg")
        self.assertEqual(epoch.isoformat(), "2016-05-18T07:38:16.611000")

    # -- media detection ----------------------------------------------------

    def test_magic_bytes_detect_extensionless_media(self):
        png = self.write(self.root / "2013-01-08", PNG)
        jpeg = self.write(self.root / "no-ext-jpeg", JPEG)
        txt = self.write(self.root / "notes", b"just text")
        self.assertEqual(self.pb.media_kind(png), "image")
        self.assertEqual(self.pb.media_kind(jpeg), "image")
        self.assertIsNone(self.pb.media_kind(txt))

    def test_extension_detection_still_works_and_splits_video(self):
        self.assertEqual(self.pb.media_kind(self.write(self.root / "a.HEIC", b"x")), "image")
        self.assertEqual(self.pb.media_kind(self.write(self.root / "b.MOV", b"x")), "video")
        self.assertEqual(self.pb.media_kind(self.write(self.root / "c.mp4", MP4)), "video")

    # -- decision log -------------------------------------------------------

    def test_log_parse_and_latest_wins_is_single_identity(self):
        log = self.root / "decisions.tsv"
        log.write_text(
            "t1\t1\t/src/a.jpg\n"
            "t2\t3\t/src/a.jpg\n"
            "malformed\n"
            "t3\t5\t/src/b.jpg\n"
        )
        decisions = self.pb.parse_decisions(str(log))
        self.assertEqual(len(decisions), 3)
        latest = self.pb.latest_by_path(decisions)
        self.assertEqual(latest["/src/a.jpg"][1], "3")
        self.assertEqual(len(self.pb.decided_paths(decisions)), 2)

    def test_decide_records_without_moving(self):
        source = self.make_source()
        photo = self.write(source / "one.jpg", JPEG)
        session, session_path = self.session(source=str(source))
        rc = self.pb.cmd_decide(self.ns(session=session, tier=7, file=photo))
        self.assertEqual(rc, 0)
        self.assertTrue(Path(photo).exists())
        self.assertFalse((session_path / "07" / "one.jpg").exists())
        decisions = self.pb.parse_decisions(str(session_path / "decisions.tsv"))
        self.assertEqual(len(decisions), 1)
        self.assertEqual(decisions[0][1], "7")
        self.assertEqual(decisions[0][2], photo)

    def test_undo_restores_previous_decision_for_path(self):
        source = self.make_source()
        photo = self.write(source / "one.jpg", JPEG)
        session, session_path = self.session(source=str(source))
        self.pb.cmd_decide(self.ns(session=session, tier=1, file=photo))
        self.pb.cmd_decide(self.ns(session=session, tier=3, file=photo))
        rc = self.pb.cmd_undo(self.ns(session=session))
        self.assertEqual(rc, 0)
        decisions = self.pb.parse_decisions(str(session_path / "decisions.tsv"))
        self.assertEqual(len(decisions), 1)
        self.assertEqual(self.pb.latest_by_path(decisions)[photo][1], "1")
        self.assertTrue(Path(photo).exists())

    def test_undo_without_decisions_errors(self):
        session, _ = self.session()
        stderr = io.StringIO()
        with redirect_stderr(stderr):
            rc = self.pb.cmd_undo(self.ns(session=session))
        self.assertEqual(rc, 1)
        self.assertIn("nothing to undo", stderr.getvalue())

    # -- apply --------------------------------------------------------------

    def test_apply_moves_with_collision_safe_naming_and_is_idempotent(self):
        source = self.make_source()
        (source / "a").mkdir()
        (source / "b").mkdir()
        first = self.write(source / "a" / "dup.jpg", b"first")
        second = self.write(source / "b" / "dup.jpg", b"second")
        session, session_path = self.session(source=str(source))
        self.pb.cmd_decide(self.ns(session=session, tier=2, file=first))
        self.pb.cmd_decide(self.ns(session=session, tier=2, file=second))

        rc = self.pb.cmd_apply(self.ns(session=session, dry_run=False))
        self.assertEqual(rc, 0)
        bucket = session_path / "02"
        self.assertTrue((bucket / "dup.jpg").exists())
        self.assertTrue((bucket / "dup-1.jpg").exists())
        self.assertFalse(Path(first).exists())
        self.assertFalse(Path(second).exists())
        applied = (session_path / "applied.tsv").read_text().strip().splitlines()
        self.assertEqual(len(applied), 2)

        # Second run: everything already moved -> no-op.
        stdout = io.StringIO()
        with redirect_stdout(stdout):
            rc = self.pb.cmd_apply(self.ns(session=session, dry_run=False))
        self.assertEqual(rc, 0)
        self.assertIn("0 move(s)", stdout.getvalue())
        self.assertEqual(
            len((session_path / "applied.tsv").read_text().strip().splitlines()), 2
        )

    def test_apply_dry_run_changes_nothing(self):
        source = self.make_source()
        photo = self.write(source / "one.jpg", JPEG)
        session, session_path = self.session(source=str(source))
        self.pb.cmd_decide(self.ns(session=session, tier=4, file=photo))
        stdout = io.StringIO()
        with redirect_stdout(stdout):
            rc = self.pb.cmd_apply(self.ns(session=session, dry_run=True))
        self.assertEqual(rc, 0)
        self.assertIn("would move tier 4", stdout.getvalue())
        self.assertTrue(Path(photo).exists())
        self.assertFalse((session_path / "04" / "one.jpg").exists())
        self.assertFalse((session_path / "applied.tsv").exists())

    def test_apply_refuses_on_conflicting_destination(self):
        source = self.make_source()
        photo = self.write(source / "one.jpg", b"new photo")
        session, session_path = self.session(source=str(source))
        bucket = session_path / "05"
        bucket.mkdir(parents=True, exist_ok=True)
        self.write(bucket / "one.jpg", b"a different photo")
        self.pb.cmd_decide(self.ns(session=session, tier=5, file=photo))
        stderr = io.StringIO()
        with redirect_stderr(stderr):
            rc = self.pb.cmd_apply(self.ns(session=session, dry_run=False))
        self.assertEqual(rc, 1)
        self.assertIn("refusing", stderr.getvalue())
        self.assertTrue(Path(photo).exists())

    # -- report / review ----------------------------------------------------

    def test_report_no_double_count_and_video_exclusion(self):
        source = self.make_source()
        first = self.write(source / "20190404_182256.jpg", JPEG)
        self.write(source / "20190405_182256.jpg", JPEG)
        self.write(source / "clip.mp4", MP4)
        session, _ = self.session(source=str(source))
        self.pb.cmd_decide(self.ns(session=session, tier=4, file=first))
        self.pb.cmd_decide(self.ns(session=session, tier=4, file=first))  # re-tag
        stdout = io.StringIO()
        with redirect_stdout(stdout):
            rc = self.pb.cmd_report(self.ns(session=session))
        self.assertEqual(rc, 0)
        output = stdout.getvalue()
        self.assertIn("tier 4: 1", output)
        self.assertIn("total decided: 1", output)
        self.assertIn("undecided remaining: 2", output)
        self.assertIn("videos excluded: 1", output)

    def test_post_apply_retag_keeps_single_identity_and_moves_bucket(self):
        source = self.make_source()
        path = self.write(source / "20190404_182256.jpg", JPEG)
        session, session_path = self.session(source=str(source))
        self.pb.read_exif_batch = lambda paths, chunk_size=500: {}
        self.pb.cmd_decide(self.ns(session=session, tier=5, file=path))
        self.pb.cmd_apply(self.ns(session=session, dry_run=False))
        bucket5 = self.root / session / "05" / "20190404_182256.jpg"
        self.assertTrue(bucket5.exists(), "apply should move the file into 05")
        # Post-apply, a tier re-review must find the file where it now lives.
        self.assertEqual(
            [Path(p).name for p in self.pb.tier_files(str(session_path), 5)],
            ["20190404_182256.jpg"],
        )
        # Re-tagging from the bucket path must not create a second identity.
        self.pb.cmd_decide(self.ns(session=session, tier=9, file=str(bucket5)))
        latest = self.pb.latest_by_path(
            self.pb.parse_decisions(self.pb.decisions_path(str(session_path)))
        )
        self.assertEqual(len(latest), 1)
        # ...and applying again relocates it to 09.
        self.pb.cmd_apply(self.ns(session=session, dry_run=False))
        self.assertTrue((self.root / session / "09" / "20190404_182256.jpg").exists())
        self.assertFalse(bucket5.exists())

    def test_review_list_sorts_by_capture_and_excludes_videos(self):
        source = self.make_source()
        later = self.write(source / "20190404_182256.jpg", JPEG, mtime=100)
        earlier = self.write(source / "20190401_100000.jpg", JPEG, mtime=900)
        no_date = self.write(source / "20190501.jpg", JPEG, mtime=500)
        self.write(source / "clip.mp4", MP4)
        session, session_path = self.session(source=str(source))
        # Keep exiftool out of the tests entirely.
        self.pb.read_exif_batch = lambda paths, chunk_size=500: {}
        photos, videos = self.pb.build_review_list(str(source), str(session_path))
        self.assertEqual(
            [Path(p).name for p in photos],
            ["20190401_100000.jpg", "20190404_182256.jpg", "20190501.jpg"],
        )
        self.assertEqual([Path(p).name for p in videos], ["clip.mp4"])

    def test_exif_batch_forces_one_line_per_file(self):
        # Without -f, a tagless file emits no line and the chunk is discarded.
        seen = {}

        class Proc:
            stdout = "2020-01-02 03:04:05\n-\n"

        def fake_run(cmd, **kwargs):
            seen["cmd"] = cmd
            return Proc()

        self.pb.exiftool_path = lambda: "/usr/bin/exiftool"
        # Patch the shared stdlib module only for the duration of the call;
        # leaving it patched leaks into the other test modules.
        with mock.patch.object(self.pb.subprocess, "run", fake_run):
            result = self.pb.read_exif_batch(["/a/one.jpg", "/a/two.jpg"])
        self.assertIn("-f", seen["cmd"])
        self.assertEqual(result, {"/a/one.jpg": "2020-01-02 03:04:05"})

    def test_review_argv_preserves_capture_order(self):
        # feh applies --sort to an explicit --filelist, so it must be "none".
        source = self.make_source()
        self.write(source / "20190404_182256.jpg", JPEG)
        self.pb.read_exif_batch = lambda paths, chunk_size=500: {}
        captured = {}
        session = self.pb.session_name(str(source))
        with mock.patch.object(
            self.pb.os, "execvp", lambda prog, argv: captured.update(prog=prog, argv=argv)
        ):
            self.pb.cmd_review(
                self.ns(src=str(source), session=session, tier=None, grid=False)
            )
        argv = captured["argv"]
        self.assertEqual(captured["prog"], "feh")
        self.assertEqual(argv[argv.index("--sort") + 1], "none")
        self.assertNotIn("mtime", argv)
        # Number keys 1-9 are the tier actions; 0/Enter is undo.
        self.assertIn("--action1", argv)
        self.assertIn("--action9", argv)
        self.assertTrue(argv[argv.index("--action") + 1].startswith("photobucket undo"))

    def test_review_list_excludes_already_decided(self):
        source = self.make_source()
        kept = self.write(source / "20190401_100000.jpg", JPEG)
        decided = self.write(source / "20190404_182256.jpg", JPEG)
        session, session_path = self.session(source=str(source))
        self.pb.read_exif_batch = lambda paths, chunk_size=500: {}
        self.pb.cmd_decide(self.ns(session=session, tier=1, file=decided))
        photos, videos = self.pb.build_review_list(str(source), str(session_path))
        self.assertEqual([Path(p).name for p in photos], [Path(kept).name])
        self.assertEqual(videos, [])


if __name__ == "__main__":
    unittest.main()
