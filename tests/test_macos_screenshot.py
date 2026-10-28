import importlib.util
import plistlib
import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "modules/desktop/macos-screenshot.py"
spec = importlib.util.spec_from_file_location("macos_screenshot", SCRIPT)
screenshot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(screenshot)
PARAMETERS = [65535, 105, 8388608]
DESIRED = {"enabled": True, "value": {"parameters": PARAMETERS, "type": "standard"}}


class ScreenshotTest(unittest.TestCase):
    def run_with(self, shortcuts):
        export = subprocess.CompletedProcess([], 0, plistlib.dumps({"AppleSymbolicHotKeys": shortcuts}), b"")
        with patch.object(screenshot.subprocess, "run", return_value=export) as run:
            result = screenshot.ensure_shortcut("defaults", "30", PARAMETERS)
        return result, run

    def test_missing_adds_only_area_shortcut(self):
        result, run = self.run_with({"28": {"enabled": False}})
        self.assertEqual(result, "configured PSCRN area screenshot")
        self.assertEqual(run.call_count, 2)
        args = run.call_args_list[1].args[0]
        self.assertEqual(args[:6], ["defaults", "write", screenshot.DOMAIN, "AppleSymbolicHotKeys", "-dict-add", "30"])
        self.assertEqual(plistlib.loads(args[6].encode()), DESIRED)

    def test_existing_matching_setting_is_untouched(self):
        result, run = self.run_with({"30": DESIRED})
        self.assertEqual(result, "already configured")
        self.assertEqual(run.call_count, 1)

    def test_existing_different_setting_is_preserved(self):
        result, run = self.run_with({"30": {"enabled": False}})
        self.assertIn("left unchanged", result)
        self.assertEqual(run.call_count, 1)

    def test_bad_dictionary_is_rejected(self):
        export = subprocess.CompletedProcess([], 0, plistlib.dumps({"AppleSymbolicHotKeys": "bad"}), b"")
        with patch.object(screenshot.subprocess, "run", return_value=export):
            with self.assertRaises(ValueError):
                screenshot.ensure_shortcut("defaults", "30", PARAMETERS)


if __name__ == "__main__":
    unittest.main()
