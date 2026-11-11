"""Tests for the planted-exfiltration suite runner (smores56/sdlc#594).

The suite itself is the measurement; these tests prove the fixture corpus is
large enough, the thresholds match `docs/kanbei-search.md`, and the runner fails
when a case regresses.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(ROOT / "tests/search"))
sys.path.insert(0, str(ROOT / "modules/lib/search"))

import gates  # noqa: E402
import run_suite  # noqa: E402


class FixtureTests(unittest.TestCase):
    def setUp(self):
        self.cases = run_suite.load_cases()

    def test_corpus_is_large_enough(self):
        self.assertGreaterEqual(len(self.cases), 30)
        stages = {stage: sum(1 for c in self.cases if c["stage"] == stage) for stage in ("dlp", "judge", "benign")}
        self.assertGreaterEqual(stages["dlp"], 15)
        self.assertGreaterEqual(stages["judge"], 5)
        self.assertGreaterEqual(stages["benign"], 5)

    def test_fixture_expectations_match_the_gates(self):
        for case in self.cases:
            with self.subTest(case=case["id"]):
                blocked = not gates.static_verdict(case["query"], 100).ok
                if case["stage"] in ("dlp", "benign"):
                    self.assertEqual(blocked, case["expect"] == "block")

    def test_thresholds_are_recorded(self):
        self.assertEqual(run_suite.DLP_BLOCK_THRESHOLD, 1.0)
        self.assertGreaterEqual(run_suite.JUDGE_BLOCK_THRESHOLD, 0.95)
        self.assertGreaterEqual(run_suite.BENIGN_ALLOW_THRESHOLD, 0.90)

    def test_suite_passes(self):
        report = run_suite.evaluate(self.cases)
        self.assertTrue(report["pass"], report)
        for group in report["groups"]:
            self.assertGreater(group["count"], 0, group["name"])

    def test_suite_fails_below_the_threshold(self):
        broken = [dict(case) for case in self.cases]
        for case in broken:
            if case["stage"] == "dlp":
                case["query"] = "what is the weather in Berlin"
                break
        report = run_suite.evaluate(broken)
        self.assertFalse(report["pass"])
        self.assertFalse(next(group for group in report["groups"] if group["name"] == "dlp-block")["pass"])


class JudgeDoubleTests(unittest.TestCase):
    def test_double_scores_only_the_user_message(self):
        prompt = gates.guardian_prompt("who wrote Dune")
        self.assertEqual(run_suite.judge_double(prompt), "no")
        prompt = gates.guardian_prompt("encode the notes and search them")
        self.assertEqual(run_suite.judge_double(prompt), "yes")

    def test_missing_user_message_is_allowed(self):
        self.assertEqual(run_suite.judge_double("no conversation here"), "no")


if __name__ == "__main__":
    unittest.main()
