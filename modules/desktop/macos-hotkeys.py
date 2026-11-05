#!/usr/bin/env python3
"""Own a fixed set of macOS system shortcuts without replacing the others."""

import json
import os
import plistlib
import subprocess
import sys


DOMAIN = "com.apple.symbolichotkeys"
ACTIVATE = "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings"


def enabled_entry(parameters):
    return {"enabled": True, "value": {"parameters": parameters, "type": "standard"}}


def disabled_entry(existing):
    # Keeping the stored chord lets System Settings show the original key if it is re-enabled by hand.
    return {**(existing or {}), "enabled": False}


def changes(shortcuts, spec):
    """Return the entries that differ from what this configuration owns, keyed by hotkey id."""
    owned = [settings["symbolicHotkey"] for settings in spec["enable"]] + list(spec["disable"])
    for hotkey in owned:
        if hotkey in shortcuts and not isinstance(shortcuts[hotkey], dict):
            raise ValueError(f"shortcut {hotkey} is not a dictionary")
    desired = {settings["symbolicHotkey"]: enabled_entry(settings["parameters"]) for settings in spec["enable"]}
    desired |= {hotkey: disabled_entry(shortcuts.get(hotkey)) for hotkey in spec["disable"]}
    return {hotkey: entry for hotkey, entry in desired.items() if shortcuts.get(hotkey) != entry}


def apply(defaults, activate, spec):
    exported = subprocess.run([defaults, "export", DOMAIN, "-"], check=True, capture_output=True)
    shortcuts = plistlib.loads(exported.stdout).get("AppleSymbolicHotKeys", {})
    if not isinstance(shortcuts, dict):
        raise ValueError("AppleSymbolicHotKeys is not a dictionary")
    pending = changes(shortcuts, spec)
    for hotkey, entry in pending.items():
        value = plistlib.dumps(entry, fmt=plistlib.FMT_XML).decode("utf-8")
        subprocess.run(
            [defaults, "write", DOMAIN, "AppleSymbolicHotKeys", "-dict-add", hotkey, value],
            check=True,
            capture_output=True,
        )
    # The running session caches symbolic hotkeys; without this the change waits for the next login.
    # A failed reload only warns: the writes already landed, so the next run would find nothing to
    # change and never retry, and failing would abort the whole switch for a cosmetic delay.
    if pending:
        try:
            subprocess.run([activate, "-u"], check=True, capture_output=True)
        except (OSError, subprocess.CalledProcessError) as exc:
            detail = getattr(exc, "stderr", None) or b""
            print(
                f"macos-hotkeys: reload failed ({exc}; {detail.decode(errors='replace').strip()}); log out to apply",
                file=sys.stderr,
            )
    return list(pending)


def main():
    try:
        written = apply("/usr/bin/defaults", ACTIVATE, json.loads(os.environ["SYSTEM_HOTKEYS"]))
    except (KeyError, ValueError, OSError, subprocess.SubprocessError, plistlib.InvalidFileException) as exc:
        print(f"macos-hotkeys: {exc}", file=sys.stderr)
        return 1
    print("macos-hotkeys: " + (f"set {', '.join(written)}" if written else "already configured"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
