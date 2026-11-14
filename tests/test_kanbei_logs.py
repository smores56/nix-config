"""Unit tests for the touch-gated log viewer's inventory.

The guest's kernel journal never reaches the host, so the serial console file is
the only trace of `inbox poll`. The viewer must include it, and a source filter
must still exclude it.
"""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

MODULE = Path(__file__).parents[1] / "modules/lib/ingest/kanbei_logs.py"


def load():
    spec = importlib.util.spec_from_file_location("kanbei_logs", MODULE)
    module = importlib.util.module_from_spec(spec)
    sys.modules["kanbei_logs"] = module
    spec.loader.exec_module(module)
    return module


class SelectLogsTests(unittest.TestCase):
    def setUp(self):
        self.viewer = load()

    def test_the_guest_console_is_in_the_inventory(self):
        self.assertIn(self.viewer.CONSOLE_FILE, self.viewer.select_logs(set()))

    def test_the_kanbei_filter_selects_the_console(self):
        self.assertIn(self.viewer.CONSOLE_FILE, self.viewer.select_logs({"kanbei"}))

    def test_another_source_filter_excludes_the_console(self):
        self.assertNotIn(self.viewer.CONSOLE_FILE, self.viewer.select_logs({"finance"}))


if __name__ == "__main__":
    unittest.main()
