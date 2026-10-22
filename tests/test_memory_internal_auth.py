import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).parents[1] / "modules/features/ai/memory/src"))

from memory_mcp.internal_auth import (  # noqa: E402
    DEFAULT_TOKEN_FILE,
    TOKEN_FILE_ENV,
    TokenError,
    bearer_ok,
    read_token,
    token_path,
    write_token,
)


class TokenFileTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.state_dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_a_generated_token_is_random_and_group_readable(self):
        first = write_token(self.state_dir)
        second = write_token(self.state_dir)
        self.assertNotEqual(first, second)
        path = token_path(self.state_dir)
        self.assertEqual(path.stat().st_mode & 0o777, 0o640)
        self.assertEqual(read_token(path), second)
        self.assertGreaterEqual(len(second), 32)

    def test_an_explicit_token_is_written_verbatim(self):
        self.assertEqual(write_token(self.state_dir, "fixed-token"), "fixed-token")
        self.assertEqual(read_token(token_path(self.state_dir)), "fixed-token")

    def test_the_environment_overrides_the_default_path(self):
        path = self.state_dir / "elsewhere.token"
        path.write_text("from-env\n", encoding="utf-8")
        with mock.patch.dict(os.environ, {TOKEN_FILE_ENV: str(path)}):
            self.assertEqual(read_token(), "from-env")
        with mock.patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(TokenError) as caught:
                read_token()
        self.assertIn(DEFAULT_TOKEN_FILE, str(caught.exception))

    def test_a_missing_or_empty_token_is_an_error(self):
        missing = self.state_dir / "missing.token"
        with self.assertRaises(TokenError):
            read_token(missing)
        empty = self.state_dir / "empty.token"
        empty.write_text("  \n", encoding="utf-8")
        with self.assertRaises(TokenError) as caught:
            read_token(empty)
        self.assertIn("empty", str(caught.exception))


class BearerTests(unittest.TestCase):
    def test_a_correct_bearer_header_is_accepted(self):
        self.assertTrue(bearer_ok("Bearer secret", "secret"))
        self.assertTrue(bearer_ok("bearer secret", "secret"))

    def test_missing_wrong_or_other_schemes_are_rejected(self):
        for header in (None, "", "secret", "Basic secret", "Bearer wrong", "Bearer "):
            with self.subTest(header=header):
                self.assertFalse(bearer_ok(header, "secret"))

    def test_an_empty_expected_token_never_matches(self):
        self.assertFalse(bearer_ok("Bearer ", ""))
        self.assertFalse(bearer_ok("Bearer anything", None))


if __name__ == "__main__":
    unittest.main()
