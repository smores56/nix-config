"""Unit tests for the search guest's pure gates (smores56/sdlc#594).

Covers normalization, every DLP pattern and the entropy rule, the length cap,
the Guardian prompt and verdict parser, and result stripping. No model, no
network and no root are needed.
"""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

SEARCH = Path(__file__).parents[1] / "modules/lib/search"
sys.path.insert(0, str(SEARCH))

import gates  # noqa: E402


class NormalizeTests(unittest.TestCase):
    def test_collapses_whitespace_and_strips(self):
        self.assertEqual(gates.normalize("  a\t b\n\nc  "), "a b c")
        self.assertEqual(gates.normalize("a\u00a0b"), "a b")

    def test_nfkc_folds_compatibility_forms(self):
        self.assertEqual(gates.normalize("ｐａｓｓｗｏｒｄ"), "password")
        self.assertEqual(gates.normalize("e\u0301"), "é")

    def test_drops_format_characters(self):
        self.assertEqual(gates.normalize("ab\u200bcd\u200eef"), "abcdef")

    def test_rejects_non_text(self):
        with self.assertRaises(TypeError):
            gates.normalize(b"bytes")


class DlpRuleTests(unittest.TestCase):
    CASES = [
        ("private-key", "-----BEGIN RSA PRIVATE KEY----- MIIE"),
        ("aws-access-key", "key AKIAIOSFODNN7EXAMPLE here"),
        ("github-token", "token ghp_000000000000000000000000000000000000"),
        ("github-token", "pat github_pat_0000000000000000000000"),
        ("slack-token", "xox" "b-00000000-00000000-abcdefghijkl"),
        (
            "jwt",
            "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0."
            "dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
        ),
        ("credentialed-url", "https://user:hunter2@example.com/path"),
        ("bearer-token", "Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345"),
        ("email", "write to owner@example.com"),
        ("ssn", "ssn 123-45-6789"),
        ("card", "card 4111 1111 1111 1111"),
        ("long-digits", "account 000123456789"),
        ("digit-run", "call 555 123 4567"),
        ("hex-blob", "9f2c4ab7d18e6035ac91f4de27b0c58391ad6e40f2b7c9a1d3e5f60817a2b4c6"),
        (
            "base64-blob",
            "VGhlIHF1aWNrIGJyb3duIGZveCBqdW1wcyBvdmVyIDEzIGxhenkgZG9ncy4=",
        ),
        ("keyword-secret", "my password is hunter22"),
        ("keyword-secret", "api_key=sk-live-abcdefghijkl"),
        ("keyword-secret", "secret: 0f8a7b6c5d4e"),
        ("keyword-secret", "recovery code is 8842-1190-7731"),
        ("entropy", "look up Zx9Qm2Lp7Rt4Vb8Nc3Wd6Kf1"),
        ("control-chars", "hello\x00world"),
    ]

    def test_every_rule_matches(self):
        for expected, text in self.CASES:
            with self.subTest(rule=expected, text=text):
                self.assertEqual(gates.dlp_rule(gates.normalize(text)), expected)

    def test_benign_text_does_not_match(self):
        for text in (
            "What is the capital of Australia?",
            "Explain a mutex versus a semaphore in operating systems",
            "How do I convert 100 USD to EUR?",
            "Latest release notes for llama.cpp",
            "The password manager comparison from 2024",
            "What is my password manager called",
            "card games for two players",
            "call me maybe lyrics",
        ):
            with self.subTest(text=text):
                self.assertIsNone(gates.dlp_rule(gates.normalize(text)))

    def test_digit_run_floor_is_nine_digits(self):
        self.assertIsNone(gates.dlp_rule("date 2024-11-11 and port 131072"))
        self.assertIsNone(gates.dlp_rule("ip 10.77.14.1"))
        self.assertEqual(gates.dlp_rule("ref 123 456 789"), "digit-run")

    def test_email_needs_a_domain(self):
        self.assertIsNone(gates.dlp_rule("at sign @ in prose"))
        self.assertEqual(gates.dlp_rule("a.b+c@d.example.org"), "email")

    def test_hex_and_base64_need_length(self):
        self.assertIsNone(gates.dlp_rule("deadbeef"))
        self.assertEqual(gates.dlp_rule("a" * 32), "hex-blob")
        self.assertEqual(gates.dlp_rule("QUJD" * 8 + "=="), "base64-blob")

    def test_keyword_needs_a_value(self):
        self.assertIsNone(gates.dlp_rule("what is my password"))
        self.assertIsNone(gates.dlp_rule("password management tips"))
        self.assertEqual(gates.dlp_rule("password: abcdef"), "keyword-secret")

    def test_entropy_needs_length_digits_and_letters(self):
        self.assertAlmostEqual(gates.shannon_entropy("aaaa"), 0.0)
        self.assertGreater(gates.shannon_entropy("abcd"), 1.9)
        self.assertFalse(gates.entropy_hit("correcthorsebatterystaple2024"))
        self.assertFalse(gates.entropy_hit("Zx9Qm2Lp7Rt4Vb8Nc3Wd6Kf"))  # 23 chars
        self.assertTrue(gates.entropy_hit("Zx9Qm2Lp7Rt4Vb8Nc3Wd6Kf1"))

    def test_dlp_never_returns_matched_text(self):
        secret = "ghp_000000000000000000000000000000000000"
        rule = gates.dlp_rule(f"token {secret}")
        self.assertEqual(rule, "github-token")
        self.assertNotIn(secret, rule or "")


class StaticVerdictTests(unittest.TestCase):
    def test_cap_boundary(self):
        base = (
            "the quick brown fox jumps over the lazy dog and then goes home to sleep tonight " * 2
        )
        query = base[:99] + "z"
        self.assertEqual(len(query), 100)
        self.assertTrue(gates.static_verdict(query, 100).ok)
        result = gates.static_verdict(query + "w", 100)
        self.assertFalse(result.ok)
        self.assertEqual(result.reason, "length")
        self.assertEqual(result.rule, "cap")

    def test_hard_cap_is_320(self):
        self.assertEqual(gates.MAX_QUERY_CHARS_HARD, 320)
        result = gates.static_verdict("a" * 321, 400)
        self.assertFalse(result.ok)

    def test_dlp_runs_before_cap(self):
        result = gates.static_verdict("owner@example.com " + "x" * 200, 100)
        self.assertEqual(result.reason, "dlp")

    def test_empty_and_non_text_block(self):
        self.assertEqual(gates.static_verdict("   ", 100).reason, "length")
        result = gates.static_verdict(None, 100)  # type: ignore[arg-type]
        self.assertFalse(result.ok)
        self.assertEqual(result.rule, "not-text")

    def test_verdict_does_not_carry_a_fingerprint_of_secret_text(self):
        result = gates.static_verdict("password: hunter22", 100)
        self.assertFalse(result.ok)
        self.assertEqual(result.rule, "keyword-secret")


class GuardianPromptTests(unittest.TestCase):
    def test_prompt_shape(self):
        prompt = gates.guardian_prompt("who wrote Dune")
        self.assertIn("<|start_of_role|>user<|end_of_role|>", prompt)
        self.assertIn("<|start_of_role|>assistant<|end_of_role|>", prompt)
        self.assertIn("<guardian>", prompt)
        self.assertIn("</guardian>", prompt)
        self.assertIn("<start_of_risk_definition>", prompt)
        self.assertIn(gates.EXFIL_CRITERION, prompt)
        self.assertIn("<score>yes</score>", prompt)
        self.assertIn("User Message: who wrote Dune", prompt)

    def test_prompt_keeps_braces_literal(self):
        prompt = gates.guardian_prompt("json {a: 1}")
        self.assertIn("User Message: json {a: 1}", prompt)

    def test_parse_score_tag(self):
        self.assertEqual(gates.parse_verdict("<score>yes</score>"), "yes")
        self.assertEqual(gates.parse_verdict("<score>\nNo\n</score>"), "no")
        self.assertEqual(gates.parse_verdict("thinking... <score>YES</score>"), "yes")

    def test_parse_think_block_is_ignored(self):
        text = " thinkingthe assistant said no earlier</think><score>yes</score>"
        self.assertEqual(gates.parse_verdict(text), "yes")

    def test_parse_bare_verdict_for_3x_models(self):
        self.assertEqual(gates.parse_verdict("Yes"), "yes")
        self.assertEqual(gates.parse_verdict(" No."), "no")
        self.assertEqual(gates.parse_verdict("YES, it is"), "yes")

    def test_missing_or_unusable_verdict_is_none(self):
        for text in ("", "maybe", "I cannot help with that", None, 42):
            with self.subTest(text=text):
                self.assertIsNone(gates.parse_verdict(text))

    def test_a_late_bare_no_is_not_a_verdict(self):
        self.assertIsNone(gates.parse_verdict("The text is safe and the answer is no"))


class StripMarkupTests(unittest.TestCase):
    def test_tags_and_scripts(self):
        self.assertEqual(gates.strip_markup("<b>Hello</b> <i>world</i>"), "Hello world")
        self.assertEqual(
            gates.strip_markup("before<script>alert(1)</script>after"), "beforeafter"
        )
        self.assertEqual(gates.strip_markup("<style>p{}</style>plain"), "plain")

    def test_entities(self):
        self.assertEqual(gates.strip_markup("a &amp; b &lt;tag&gt;"), "a & b tag")

    def test_markdown_links_keep_labels(self):
        self.assertEqual(gates.strip_markup("[label](https://x.test)"), "label")
        self.assertEqual(gates.strip_markup("![alt](https://x.test/a.png)"), "alt")
        self.assertEqual(gates.strip_markup("<https://x.test/a>"), "")

    def test_control_and_format_characters_are_dropped(self):
        self.assertEqual(gates.strip_markup("a\x00b\u200bc"), "abc")

    def test_non_text_is_empty(self):
        self.assertEqual(gates.strip_markup(None), "")
        self.assertEqual(gates.strip_markup(5), "")


class SanitizeResultsTests(unittest.TestCase):
    def setUp(self):
        self.payload = {
            "results": [
                {
                    "title": "<b>Result</b>",
                    "url": "https://example.com/page?a=1",
                    "snippet": "A &amp; B",
                    "raw": {"keep": "nothing"},
                }
            ]
        }

    def test_strips_and_keeps_plain_fields(self):
        results, truncated = gates.sanitize_results(self.payload)
        self.assertEqual(
            results,
            [{"title": "Result", "url": "https://example.com/page?a=1", "snippet": "A & B"}],
        )
        self.assertFalse(truncated)

    def test_drops_unsafe_urls(self):
        for url in (
            "javascript:alert(1)",
            "https://user:pass@example.com/",
            "https://example.com/ space",
            "ftp://example.com/file",
            "x" * (gates.MAX_URL_CHARS + 1),
        ):
            with self.subTest(url=url[:30]):
                payload = {"results": [{"title": "t", "url": url, "snippet": "s"}]}
                results, _ = gates.sanitize_results(payload)
                self.assertEqual(results[0]["url"], "")

    def test_bounds_each_field(self):
        payload = {
            "results": [
                {
                    "title": "t" * 500,
                    "url": "https://example.com/",
                    "snippet": "s" * 900,
                }
            ]
        }
        results, truncated = gates.sanitize_results(payload)
        self.assertTrue(truncated)
        self.assertLessEqual(len(results[0]["title"]), gates.MAX_TITLE_CHARS)
        self.assertLessEqual(len(results[0]["snippet"]), gates.MAX_SNIPPET_CHARS)
        self.assertTrue(results[0]["title"].endswith("\u2026"))

    def test_result_count_and_byte_bounds(self):
        payload = {"results": [{"title": f"t{i}", "url": "", "snippet": "s"} for i in range(10)]}
        results, truncated = gates.sanitize_results(payload)
        self.assertEqual(len(results), gates.MAX_RESULTS)
        self.assertTrue(truncated)
        payload = {"results": [{"title": "t", "url": "", "snippet": "s" * 390} for _ in range(5)]}
        results, truncated = gates.sanitize_results(payload, max_bytes=800)
        self.assertTrue(truncated)
        self.assertLess(len(results), 5)

    def test_malformed_payloads_raise(self):
        for payload in ([], {}, {"results": {}}, {"results": [1]}, None):
            with self.subTest(payload=payload):
                with self.assertRaises(ValueError):
                    gates.sanitize_results(payload)

    def test_json_round_trip_is_inert_text(self):
        payload = {"results": [{"title": "<img src=x onerror=1>", "url": "", "snippet": "[x](y)"}]}
        results, _ = gates.sanitize_results(payload)
        encoded = json.dumps(results)
        self.assertNotIn("<", encoded)
        self.assertNotIn("onerror", encoded)
        self.assertIn("x", encoded)


if __name__ == "__main__":
    unittest.main()
