"""Path-confinement tests for the read-only filesystem tool server.

The security property under test is that a path outside the allowlisted roots
is refused — including the two shapes that defeated the upstream MCP
filesystem server: a sibling directory whose name shares a prefix, and a
symlink that escapes the root.
"""

import importlib.util
import pathlib
import tempfile
import unittest


def load_module():
    path = (
        pathlib.Path(__file__).parents[1] / "modules/nixos/chatbot-src/path_guard.py"
    )
    spec = importlib.util.spec_from_file_location("path_guard", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class PathGuardTests(unittest.TestCase):
    def setUp(self):
        self.guard = load_module()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = pathlib.Path(self.tmp.name)

        self.allowed = root / "allowed"
        self.allowed.mkdir()
        (self.allowed / "ok.txt").write_text("hello")

        # Sibling whose name shares a prefix with the allowed root.
        self.evil = root / "allowed-evil"
        self.evil.mkdir()
        (self.evil / "secret.txt").write_text("should never be readable")

        outside = root / "outside"
        outside.mkdir()
        (outside / "target.txt").write_text("outside the root")
        (self.allowed / "escape").symlink_to(outside)

    def test_accepts_path_inside_root(self):
        resolved = self.guard.normalize_path(
            str(self.allowed / "ok.txt"), [self.allowed]
        )
        self.assertEqual(resolved, (self.allowed / "ok.txt").resolve())

    def test_accepts_root_itself(self):
        resolved = self.guard.normalize_path(str(self.allowed), [self.allowed])
        self.assertEqual(resolved, self.allowed.resolve())

    def test_rejects_path_outside_root(self):
        with self.assertRaises(self.guard.AccessDenied):
            self.guard.normalize_path(str(self.evil / "secret.txt"), [self.allowed])

    def test_rejects_prefix_collision_sibling(self):
        # 'allowed-evil' must not match the root 'allowed'.
        with self.assertRaises(self.guard.AccessDenied):
            self.guard.normalize_path(str(self.evil), [self.allowed])

    def test_rejects_parent_of_root(self):
        with self.assertRaises(self.guard.AccessDenied):
            self.guard.normalize_path(str(self.allowed.parent), [self.allowed])

    def test_rejects_symlink_escape(self):
        with self.assertRaises(self.guard.AccessDenied):
            self.guard.normalize_path(
                str(self.allowed / "escape" / "target.txt"), [self.allowed]
            )

    def test_rejects_nul_byte(self):
        with self.assertRaises(self.guard.InvalidPath):
            self.guard.normalize_path(
                str(self.allowed / "ok.txt") + "\x00.png", [self.allowed]
            )

    def test_parse_allowed_ignores_blanks_and_expands_tilde(self):
        roots = self.guard.parse_allowed(f"{self.allowed}::  ")
        self.assertEqual(roots, [self.allowed.resolve()])


if __name__ == "__main__":
    unittest.main()
