#!/usr/bin/env python3
"""Install the PSCRN screenshot shortcut without replacing other hotkeys."""

import json
import os
import plistlib
import subprocess
import sys


DOMAIN = "com.apple.symbolichotkeys"


def ensure_shortcut(defaults, hotkey, parameters):
    exported = subprocess.run([defaults, "export", DOMAIN, "-"], check=True, capture_output=True)
    settings = plistlib.loads(exported.stdout)
    shortcuts = settings.get("AppleSymbolicHotKeys", {})
    if not isinstance(shortcuts, dict):
        raise ValueError("AppleSymbolicHotKeys is not a dictionary")
    desired = {"enabled": True, "value": {"parameters": parameters, "type": "standard"}}
    existing = shortcuts.get(hotkey)
    if existing is not None:
        if (
            isinstance(existing, dict)
            and existing.get("enabled") is True
            and isinstance(existing.get("value"), dict)
            and existing["value"].get("parameters") == parameters
            and existing["value"].get("type") == "standard"
        ):
            return "already configured"
        return "existing area screenshot shortcut differs; left unchanged"
    # dict-add changes only this entry, rather than replacing the dictionary.
    value = plistlib.dumps(desired, fmt=plistlib.FMT_XML).decode("utf-8")
    subprocess.run(
        [defaults, "write", DOMAIN, "AppleSymbolicHotKeys", "-dict-add", hotkey, value],
        check=True,
        capture_output=True,
    )
    return "configured PSCRN area screenshot"


def main():
    try:
        settings = json.loads(os.environ["SCREENSHOT_SHORTCUT"])
        print("macos-screenshot: " + ensure_shortcut("/usr/bin/defaults", settings["symbolicHotkey"], settings["parameters"]))
    except (KeyError, ValueError, OSError, subprocess.SubprocessError, plistlib.InvalidFileException) as exc:
        print(f"macos-screenshot: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
