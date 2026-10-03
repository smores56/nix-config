import base64
import importlib.util
import io
import json
import os
import shutil
import tempfile
import unittest
from contextlib import redirect_stdout
from datetime import datetime, timezone
from pathlib import Path

# Minimal but *valid* 1x1 JPEG: exiftool refuses to write tags into a truncated
# SOI-only stub, and the normalize path must exercise real tag writing.
JPEG = base64.b64decode(
    "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0a"
    "HBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAA"
    "AAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q=="
)


def load_module():
    path = Path(__file__).parents[1] / "modules/features/immich/immich_ingest.py"
    spec = importlib.util.spec_from_file_location("immich_ingest", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def utc(*args, **kwargs):
    return datetime(*args, tzinfo=timezone.utc).replace(tzinfo=None)


class ImmichIngestTests(unittest.TestCase):
    def setUp(self):
        self.mod = load_module()
        self.tmp = tempfile.TemporaryDirectory()
        self.tmp_path = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    @staticmethod
    def write(path, content=JPEG, mtime=1_600_000_000):
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content if isinstance(content, bytes) else content.encode())
        os.utime(path, (mtime, mtime))
        return str(path.resolve())

    def sidecar(self, media_path, **fields):
        payload = {"photoTakenTime": fields}
        path = f"{media_path}.supplemental-metadata.json"
        Path(path).write_text(json.dumps(payload))
        return path

    # -- resolution priority -------------------------------------------------

    def test_sidecar_beats_filename_exif_mtime(self):
        ts = int(datetime(2015, 6, 15, 10, 0, 0, tzinfo=timezone.utc).timestamp())
        media = self.write(self.tmp_path / "20190404_182256.jpg", mtime=1_600_000_000)
        self.sidecar(media, timestamp=str(ts))
        when, source = self.mod.resolve_capture(
            media, exif="2001-01-01 00:00:00", mtime=1_600_000_000
        )
        self.assertEqual(source, "sidecar")
        self.assertEqual(when, utc(2015, 6, 15, 10, 0, 0))

    def test_sidecar_formatted_only(self):
        media = self.write(self.tmp_path / "photo.jpg")
        self.sidecar(media, formatted="Apr 4, 2019, 6:22:56 PM UTC")
        when, source = self.mod.resolve_capture(media, mtime=1_600_000_000)
        self.assertEqual(source, "sidecar")
        self.assertEqual(when, utc(2019, 4, 4, 18, 22, 56))

    def test_sidecar_stem_json_variant(self):
        media = self.write(self.tmp_path / "photo.jpg")
        Path(self.tmp_path / "photo.json").write_text(
            json.dumps(
                {"photoTakenTime": {"timestamp": str(int(datetime(2011, 1, 2, 3, 4, 5, tzinfo=timezone.utc).timestamp()))}}
            )
        )
        when, source = self.mod.resolve_capture(media, mtime=1_600_000_000)
        self.assertEqual(source, "sidecar")
        self.assertEqual(when, utc(2011, 1, 2, 3, 4, 5))

    def test_filename_fallback(self):
        media = self.write(self.tmp_path / "20190404_182256.jpg")
        when, source = self.mod.resolve_capture(
            media, exif="2001-01-01 00:00:00", mtime=1_600_000_000
        )
        self.assertEqual(source, "filename")
        self.assertEqual(when, datetime(2019, 4, 4, 18, 22, 56))

    def test_epoch_ms_filename(self):
        media = self.write(self.tmp_path / "1463557096611.jpg")
        when, source = self.mod.resolve_capture(media, mtime=1_600_000_000)
        self.assertEqual(source, "filename")
        self.assertEqual(when, utc(2016, 5, 18, 7, 38, 16))

    def test_office_lens_filename(self):
        media = self.write(self.tmp_path / "10_23_17 2_05 AM Office Lens.jpg")
        when, source = self.mod.resolve_capture(media, mtime=1_600_000_000)
        self.assertEqual(source, "filename")
        self.assertEqual(when, datetime(2017, 10, 23, 2, 5))

    def test_exif_fallback(self):
        media = self.write(self.tmp_path / "photo.jpg")
        when, source = self.mod.resolve_capture(
            media, exif="2002-02-02 03:04:05", mtime=1_600_000_000
        )
        self.assertEqual(source, "exif")
        self.assertEqual(when, datetime(2002, 2, 2, 3, 4, 5))

    def test_mtime_last_is_labelled_unreliable(self):
        media = self.write(self.tmp_path / "photo.jpg", mtime=1_600_000_000)
        when, source = self.mod.resolve_capture(media, mtime=1_600_000_000)
        self.assertEqual(source, "mtime")
        self.assertEqual(when, datetime.fromtimestamp(1_600_000_000))

    def test_truly_undated_is_unresolved(self):
        when, source = self.mod.resolve_capture(
            str(self.tmp_path / "photo.jpg"), mtime=None
        )
        self.assertIsNone(when)
        self.assertIsNone(source)

    # -- plan / collision report ---------------------------------------------

    def test_collect_plan_reports_sources(self):
        sidecar_media = self.write(self.tmp_path / "20190404_182256.jpg")
        self.sidecar(
            sidecar_media,
            timestamp=str(int(datetime(2015, 1, 1, 0, 0, 0, tzinfo=timezone.utc).timestamp())),
        )
        filename_media = self.write(self.tmp_path / "20180505_120000.jpg")
        plain = self.write(self.tmp_path / "photo.jpg", mtime=1_600_000_000)
        rows = self.mod.collect_plan([sidecar_media, filename_media, plain])
        sources = {Path(r.path).name: r.source for r in rows}
        self.assertEqual(sources["20190404_182256.jpg"], "sidecar")
        self.assertEqual(sources["20180505_120000.jpg"], "filename")
        self.assertEqual(sources["photo.jpg"], "mtime")

    def test_collisions_same_day_and_basename(self):
        first = self.write(self.tmp_path / "a" / "20180505_120000.jpg")
        second = self.write(self.tmp_path / "b" / "20180505_120000.jpg")
        distinct = self.write(self.tmp_path / "c" / "20180506_120000.jpg")
        rows = self.mod.collect_plan([first, second, distinct])
        groups = self.mod.collisions(rows)
        self.assertEqual(len(groups), 1)
        key, members = next(iter(groups.items()))
        self.assertEqual(key[1], "20180505_120000.jpg")
        self.assertEqual(len(members), 2)

    def test_cmd_plan_exit_zero_and_report(self):
        self.write(self.tmp_path / "20180505_120000.jpg")
        buf = io.StringIO()
        with redirect_stdout(buf):
            code = self.mod.main(["plan", self.tmp.name])
        self.assertEqual(code, 0)
        self.assertIn("filename", buf.getvalue())
        self.assertIn("Total media files: 1", buf.getvalue())

    def test_cmd_plan_unresolved_returns_nonzero(self):
        rows = [self.mod.Row(path=str(self.tmp_path / "ghost.jpg"), when=None, source=None)]
        code, text = self.mod.report_plan(rows)
        self.assertEqual(code, 1)
        self.assertIn("Unresolved: 1", text)
        self.assertIn("ghost.jpg", text)

    def test_cmd_plan_lists_mtime_as_unreliable(self):
        self.write(self.tmp_path / "photo.jpg", mtime=1_600_000_000)
        buf = io.StringIO()
        with redirect_stdout(buf):
            self.mod.main(["plan", self.tmp.name])
        self.assertIn("mtime", buf.getvalue())
        self.assertIn("unreliable", buf.getvalue())

    # -- normalize -----------------------------------------------------------

    def test_plan_normalize_flags_only_when_different(self):
        media = self.write(self.tmp_path / "photo.jpg", mtime=1_600_000_000)
        when = datetime(2018, 3, 4, 5, 6, 7)
        rows = [self.mod.Row(path=media, when=when, source="filename")]
        # Existing EXIF already correct and mtime already correct -> no writes.
        current_exif = {media: when.strftime("%Y-%m-%d %H:%M:%S")}
        already = self.mod.plan_normalize(rows, current_exif, current_mtime={media: int(when.timestamp())})
        self.assertFalse(already[0].write_exif)
        self.assertFalse(already[0].write_mtime)

        fresh = self.mod.plan_normalize(rows, {}, {media: 1})
        self.assertTrue(fresh[0].write_exif)
        self.assertTrue(fresh[0].write_mtime)

    def test_cmd_normalize_dry_run_does_not_write(self):
        media = self.write(self.tmp_path / "photo.jpg", mtime=1_000_000_000)
        buf = io.StringIO()
        with redirect_stdout(buf):
            code = self.mod.main(["normalize", "--dry-run", self.tmp.name])
        self.assertEqual(code, 0)
        self.assertEqual(int(os.path.getmtime(media)), 1_000_000_000)
        self.assertIn("dry-run", buf.getvalue())

    @unittest.skipUnless(shutil.which("exiftool"), "exiftool not installed")
    def test_normalize_writes_and_is_idempotent(self):
        media = self.write(self.tmp_path / "20180505_120000.jpg", mtime=1_000_000_000)
        expected = datetime(2018, 5, 5, 12, 0, 0)

        first = io.StringIO()
        with redirect_stdout(first):
            code = self.mod.main(["normalize", self.tmp.name])
        self.assertEqual(code, 0)

        exif = self.mod.read_exif_batch([media])
        self.assertEqual(exif.get(media), expected.strftime("%Y-%m-%d %H:%M:%S"))
        self.assertEqual(int(os.path.getmtime(media)), int(expected.timestamp()))

        second = io.StringIO()
        with redirect_stdout(second):
            code = self.mod.main(["normalize", self.tmp.name])
        self.assertEqual(code, 0)
        self.assertIn("0 files changed", second.getvalue())

    @unittest.skipUnless(shutil.which("exiftool"), "exiftool not installed")
    def test_normalize_mtime_source_idempotent_with_fractional_mtime(self):
        # Regresses the second-precision fix: a sub-second mtime must not cause
        # a second normalize pass once EXIF (whole seconds) starts winning.
        media = self.write(self.tmp_path / "mystery.jpg", mtime=1_600_000_000.75)
        with redirect_stdout(io.StringIO()):
            self.mod.main(["normalize", self.tmp.name])
        again = io.StringIO()
        with redirect_stdout(again):
            self.mod.main(["normalize", self.tmp.name])
        self.assertIn("0 files changed", again.getvalue())
        exif = self.mod.read_exif_batch([media])
        expected = datetime.fromtimestamp(1_600_000_000).strftime("%Y-%m-%d %H:%M:%S")
        self.assertEqual(exif.get(media), expected)


if __name__ == "__main__":
    unittest.main()
