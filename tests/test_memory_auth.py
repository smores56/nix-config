import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).parents[1] / "modules/features/ai/memory/src"))

from memory_mcp import mcp_auth  # noqa: E402


class AccessHeaderTests(unittest.TestCase):
    """The Cloudflare Access service token the tunnel hostname's edge requires."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.id_file = self.root / "access-id"
        self.secret_file = self.root / "access-secret"
        patcher = mock.patch.dict(
            os.environ,
            {
                "MEMORY_ACCESS_CLIENT_ID_FILE": str(self.id_file),
                "MEMORY_ACCESS_CLIENT_SECRET_FILE": str(self.secret_file),
            },
        )
        patcher.start()
        self.addCleanup(patcher.stop)

    def write_pair(self, client_id="access-id-value", client_secret="access-secret-value"):
        self.id_file.write_text(client_id)
        self.secret_file.write_text(client_secret)

    def test_both_files_send_both_headers(self):
        self.write_pair()
        self.assertEqual(
            dict(mcp_auth.access_headers()),
            {
                "CF-Access-Client-Id": "access-id-value",
                "CF-Access-Client-Secret": "access-secret-value",
            },
        )

    def test_neither_file_sends_no_access_headers(self):
        self.assertEqual(mcp_auth.access_headers(), ())

    def test_only_the_client_id_file_is_refused(self):
        self.id_file.write_text("access-id-value")
        with self.assertRaises(mcp_auth.TokenMissingError) as raised:
            mcp_auth.access_headers()
        self.assertIn("memory-access-client-secret", str(raised.exception))

    def test_only_the_client_secret_file_is_refused(self):
        self.secret_file.write_text("access-secret-value")
        with self.assertRaises(mcp_auth.TokenMissingError) as raised:
            mcp_auth.access_headers()
        self.assertIn("memory-access-client-id", str(raised.exception))

    def test_an_empty_value_is_refused(self):
        self.write_pair(client_id="   ")
        with self.assertRaises(mcp_auth.TokenMissingError):
            mcp_auth.access_headers()

    def test_values_are_stripped(self):
        self.write_pair(client_id="id\n", client_secret="secret\n")
        self.assertEqual(
            dict(mcp_auth.access_headers()),
            {"CF-Access-Client-Id": "id", "CF-Access-Client-Secret": "secret"},
        )

    def test_the_env_overrides_win_over_the_default_paths(self):
        default_id = self.root / "default-id"
        default_secret = self.root / "default-secret"
        default_id.write_text("default-id-value")
        default_secret.write_text("default-secret-value")
        self.write_pair()
        with (
            mock.patch.object(mcp_auth, "DEFAULT_ACCESS_ID_FILE", str(default_id)),
            mock.patch.object(mcp_auth, "DEFAULT_ACCESS_SECRET_FILE", str(default_secret)),
        ):
            headers = dict(mcp_auth.access_headers())
        self.assertEqual(headers["CF-Access-Client-Id"], "access-id-value")
        self.assertEqual(headers["CF-Access-Client-Secret"], "access-secret-value")

    def test_the_default_paths_are_the_rendered_sops_secrets(self):
        self.assertEqual(
            mcp_auth.DEFAULT_ACCESS_ID_FILE, "/run/secrets/memory-access-client-id"
        )
        self.assertEqual(
            mcp_auth.DEFAULT_ACCESS_SECRET_FILE, "/run/secrets/memory-access-client-secret"
        )

    def test_the_bearer_headers_are_unaffected(self):
        token = self.root / "token"
        token.write_text("bearer-token\n")
        self.write_pair()
        self.assertEqual(mcp_auth.authorization(token), ("Authorization", "Bearer bearer-token"))
        self.assertEqual(
            dict(mcp_auth.access_headers())["CF-Access-Client-Id"], "access-id-value"
        )


if __name__ == "__main__":
    unittest.main()
