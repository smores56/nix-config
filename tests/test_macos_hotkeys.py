import importlib.util
import plistlib
import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "modules/desktop/macos-hotkeys.py"
spec = importlib.util.spec_from_file_location("macos_hotkeys", SCRIPT)
hotkeys = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hotkeys)
PARAMETERS = [65535, 105, 8388608]
ENABLED = {"enabled": True, "value": {"parameters": PARAMETERS, "type": "standard"}}
SPEC = {"enable": [{"symbolicHotkey": "28", "parameters": PARAMETERS}], "disable": ["79"]}


class ChangesTest(unittest.TestCase):
    def test_missing_entries_are_written(self):
        self.assertEqual(hotkeys.changes({}, SPEC), {"28": ENABLED, "79": {"enabled": False}})

    def test_matching_entries_are_untouched(self):
        self.assertEqual(hotkeys.changes({"28": ENABLED, "79": {"enabled": False}}, SPEC), {})

    def test_owned_shortcut_with_other_keys_is_overwritten(self):
        stale = {"enabled": True, "value": {"parameters": [65535, 105, 8650752], "type": "standard"}}
        self.assertEqual(hotkeys.changes({"28": stale, "79": {"enabled": False}}, SPEC), {"28": ENABLED})

    def test_disabling_keeps_the_stored_shortcut(self):
        value = {"parameters": [65535, 123, 8650752], "type": "standard"}
        result = hotkeys.changes({"28": ENABLED, "79": {"enabled": True, "value": value}}, SPEC)
        self.assertEqual(result, {"79": {"enabled": False, "value": value}})

    def test_bad_dictionary_is_rejected(self):
        with self.assertRaises(ValueError):
            hotkeys.changes({"28": "bad"}, SPEC)


class ApplyTest(unittest.TestCase):
    def run_with(self, shortcuts):
        export = subprocess.CompletedProcess([], 0, plistlib.dumps({"AppleSymbolicHotKeys": shortcuts}), b"")
        with patch.object(hotkeys.subprocess, "run", return_value=export) as run:
            written = hotkeys.apply("defaults", "activate", SPEC)
        return written, [call.args[0] for call in run.call_args_list]

    def test_writes_changes_then_reloads(self):
        written, calls = self.run_with({"28": ENABLED})
        self.assertEqual(written, ["79"])
        self.assertEqual(calls[1][:6], ["defaults", "write", hotkeys.DOMAIN, "AppleSymbolicHotKeys", "-dict-add", "79"])
        self.assertEqual(plistlib.loads(calls[1][6].encode()), {"enabled": False})
        self.assertEqual(calls[2], ["activate", "-u"])

    def test_nothing_to_do_skips_the_reload(self):
        written, calls = self.run_with({"28": ENABLED, "79": {"enabled": False}})
        self.assertEqual(written, [])
        self.assertEqual(len(calls), 1)

    def test_non_dictionary_export_is_rejected(self):
        export = subprocess.CompletedProcess([], 0, plistlib.dumps({"AppleSymbolicHotKeys": "bad"}), b"")
        with patch.object(hotkeys.subprocess, "run", return_value=export):
            with self.assertRaises(ValueError):
                hotkeys.apply("defaults", "activate", SPEC)


if __name__ == "__main__":
    unittest.main()
