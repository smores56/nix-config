import hashlib
import sys
import tempfile
import unittest
from itertools import combinations
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from PIL import Image  # noqa: E402

from photo_triage_fixtures import (  # noqa: E402
    dark_fraction,
    dhash,
    edge_energy,
    generate_corpus,
    hamming,
    mean_luma,
    white_fraction,
)


class CorpusTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.TemporaryDirectory()
        cls.manifest = generate_corpus(Path(cls._tmp.name))

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()

    def image(self, photo_id):
        with Image.open(self.manifest[photo_id]["path"]) as image:
            return image.convert("RGB")

    def test_manifest_matches_the_files(self):
        for photo_id, entry in self.manifest.items():
            with self.subTest(photo_id=photo_id):
                path = Path(entry["path"])
                self.assertTrue(path.is_file())
                self.assertEqual(
                    hashlib.sha256(path.read_bytes()).hexdigest(), entry["sha256"]
                )
                with Image.open(path) as image:
                    self.assertEqual((image.width, image.height), (entry["width"], entry["height"]))

    def test_corpus_is_reproducible(self):
        with tempfile.TemporaryDirectory() as tmp:
            second = generate_corpus(tmp)
        self.assertEqual(set(second), set(self.manifest))
        for photo_id, entry in self.manifest.items():
            with self.subTest(photo_id=photo_id):
                self.assertEqual(second[photo_id]["sha256"], entry["sha256"])

    def test_expected_defects_are_observable(self):
        probes = {
            "blur": lambda image: edge_energy(image) < edge_energy(self.image("keep")) * 0.8,
            "dark": lambda image: mean_luma(image) < 60,
            "bright": lambda image: mean_luma(image) > 180,
            "screenshot": lambda image: white_fraction(image) > 0.5,
            "document": lambda image: white_fraction(image) > 0.5,
            "obstruction": lambda image: dark_fraction(image) > 0.3,
            "low_res": lambda image: min(image.size) < 100,
            "duplicate": lambda image: True,
        }
        for photo_id, entry in self.manifest.items():
            for defect in entry["expected_defects"]:
                with self.subTest(photo_id=photo_id, defect=defect):
                    self.assertIn(defect, probes)
                    self.assertTrue(probes[defect](self.image(photo_id)))
            if not entry["expected_defects"]:
                self.assertEqual(photo_id, "keep")
                self.assertLess(white_fraction(self.image(photo_id)), 0.5)

    def test_only_the_duplicate_pair_is_near(self):
        ids = sorted(self.manifest)
        for left, right in combinations(ids, 2):
            distance = hamming(dhash(self.image(left)), dhash(self.image(right)))
            close = distance <= 12
            with self.subTest(left=left, right=right, distance=distance):
                if {left, right} == {"duplicate-a", "duplicate-b"}:
                    self.assertTrue(close)
                else:
                    self.assertFalse(close)

    def test_tiny_is_small(self):
        self.assertEqual(self.image("tiny").size, (64, 48))


if __name__ == "__main__":
    unittest.main()
