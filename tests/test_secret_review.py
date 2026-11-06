import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path


def load_module():
    path = Path(__file__).parents[1] / "modules/features/secret-sweep/review.py"
    spec = importlib.util.spec_from_file_location("secret_review", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


SECRET = "ghp_" + "A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8"


class SecretReviewTests(unittest.TestCase):
    def setUp(self):
        self.sr = load_module()
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.a = root / "a.env"
        self.a.write_text("one\nTOKEN=" + SECRET + "\nthree\n")
        self.b = root / "b.log"
        self.b.write_text("x" * 1000 + SECRET + "\n")
        self.findings = [
            {"File": str(self.a), "StartLine": 2, "RuleID": "github-pat", "Secret": SECRET, "Match": "TOKEN=" + SECRET},
            {"File": str(self.b), "StartLine": 1, "RuleID": "github-pat", "Secret": SECRET, "Match": SECRET},
            {"File": str(self.a), "StartLine": 2, "RuleID": "generic-api-key", "Secret": "changeme123", "Match": "x"},
        ]

    def tearDown(self):
        self.tmp.cleanup()

    def test_prepare_dedupes_by_rule_and_secret(self):
        items = self.sr.prepare(self.findings)
        self.assertEqual(len(items), 2)
        pat = next(i for i in items if i["rule"] == "github-pat")
        self.assertEqual(pat["count"], 2)
        self.assertEqual(len(pat["files"]), 2)

    def test_keys_do_not_reveal_the_secret(self):
        for item in self.sr.prepare(self.findings):
            self.assertNotIn(SECRET[4:12], item["key"])

    def test_context_is_bounded(self):
        for item in self.sr.prepare(self.findings):
            for line in item["context"]:
                self.assertLessEqual(len(line), self.sr.CONTEXT_CHARS)

    def test_scrub_withholds_reasons_that_echo_the_secret(self):
        self.assertEqual(self.sr.scrub("looks like " + SECRET[6:14], SECRET), "(withheld)")
        self.assertEqual(self.sr.scrub("a test fixture", SECRET), "a test fixture")

    def test_scrub_withholds_long_opaque_runs_and_truncates(self):
        self.assertEqual(self.sr.scrub("value Zm9vYmFyYmF6cXV4cXV1eHh4eXl5", "other"), "(withheld)")
        self.assertLessEqual(len(self.sr.scrub("word " * 100, "other")), self.sr.REASON_CHARS)

    def test_parse_verdicts_defaults_to_unsure(self):
        keys = ["k1", "k2", "k3"]
        raw = json.dumps({"verdicts": [
            {"key": "k1", "verdict": "test", "reason": "fixture"},
            {"key": "k2", "verdict": "bogus", "reason": "?"},
            {"key": "zz", "verdict": "real", "reason": "unknown key"},
        ]})
        got = self.sr.parse_verdicts(raw, keys)
        self.assertEqual(got["k1"][0], "test")
        self.assertEqual(got["k2"][0], "unsure")
        self.assertEqual(got["k3"][0], "unsure")
        self.assertNotIn("zz", got)
        self.assertEqual(self.sr.parse_verdicts("not json", keys)["k1"][0], "unsure")

    def test_report_never_contains_secret_values(self):
        items = self.sr.prepare(self.findings)
        verdicts = {i["key"]: ("real", "live token " + SECRET) for i in items}
        out = io.StringIO()
        self.sr.write_report(self.findings, verdicts, out)
        text = out.getvalue()
        self.assertNotIn(SECRET, text)
        self.assertNotIn(SECRET[4:20], text)
        self.assertNotIn("changeme123", text)
        self.assertIn(str(self.a) + ":2", text)

    def test_classify_scrubs_model_echoes_and_survives_failures(self):
        items = self.sr.prepare(self.findings)
        lines = [json.dumps(i) for i in items]

        def echo(batch):
            return json.dumps({"verdicts": [
                {"key": i["key"], "verdict": "real", "reason": "it is " + i["secret"]} for i in batch
            ]})

        out = io.StringIO()
        self.sr.classify(lines, out, ask=echo)
        self.assertNotIn(SECRET[4:12], out.getvalue())
        self.assertNotIn("changeme123", out.getvalue())

        def boom(batch):
            raise RuntimeError("down")

        out = io.StringIO()
        self.sr.classify(lines, out, ask=boom)
        rows = [json.loads(l) for l in out.getvalue().splitlines()]
        self.assertEqual({r["verdict"] for r in rows}, {"unsure"})
        self.assertEqual(len(rows), len(items))


if __name__ == "__main__":
    unittest.main()
