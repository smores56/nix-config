#!/usr/bin/env python3
"""Switch theme mode (dark/light) and apply matching themes."""

import argparse
import os
import subprocess
from pathlib import Path

STATE_DIR = Path.home() / ".local/state/theme"
TINTY = os.environ.get("TINTY", "tinty")
DEFAULTS = {
    "dark_shell": os.environ.get("DEFAULT_DARK_SHELL", "base16-rose-pine-moon"),
    "light_shell": os.environ.get("DEFAULT_LIGHT_SHELL", "base16-rose-pine-dawn"),
    "dark_editor": os.environ.get("DEFAULT_DARK_EDITOR", "rose_pine_moon"),
    "light_editor": os.environ.get("DEFAULT_LIGHT_EDITOR", "rose_pine_dawn"),
}


def read_pref(name):
    try:
        return (STATE_DIR / name).read_text().strip()
    except FileNotFoundError:
        return ""


def write_pref(name, value):
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    (STATE_DIR / name).write_text(value + "\n")


def current_mode():
    return read_pref("mode") or "dark"


def detect_mode():
    try:
        result = subprocess.run(
            ["gsettings", "get", "org.gnome.desktop.interface", "color-scheme"],
            capture_output=True, text=True, timeout=2,
        )
        return "light" if "'prefer-light'" in result.stdout else "dark"
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return current_mode()


def resolve_theme(mode, kind):
    return read_pref(f"{mode}_{kind}") or read_pref(f"dark_{kind}") or DEFAULTS[f"dark_{kind}"]


def apply_mode(mode):
    write_pref("mode", mode)

    shell_theme = resolve_theme(mode, "shell")
    subprocess.run([TINTY, "apply", shell_theme], capture_output=True)

    editor_theme = resolve_theme(mode, "editor")
    helix_dir = Path.home() / ".config/helix/themes"
    helix_dir.mkdir(parents=True, exist_ok=True)
    (helix_dir / "active.toml").write_text(f'inherits = "{editor_theme}"\n')


def init_defaults():
    if (STATE_DIR / "mode").exists():
        return
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    write_pref("mode", "dark")
    for key, value in DEFAULTS.items():
        write_pref(key, value)


def main():
    parser = argparse.ArgumentParser(description="Switch theme mode and apply matching themes")
    sub = parser.add_subparsers(dest="command")

    sub.add_parser("dark", help="Switch to dark mode")
    sub.add_parser("light", help="Switch to light mode")
    sub.add_parser("toggle", help="Toggle between dark and light")
    sub.add_parser("detect", help="Auto-detect mode from system settings")
    sub.add_parser("init", help="Seed default preferences if missing")
    sub.add_parser("current", help="Print current mode")

    save_p = sub.add_parser("save", help="Save a theme for the current mode")
    save_p.add_argument("kind", choices=["shell", "editor"])
    save_p.add_argument("theme")

    clear_p = sub.add_parser("clear-light", help="Remove light theme variant")
    clear_p.add_argument("target", nargs="?", default="both", choices=["shell", "editor", "both"])

    args = parser.parse_args()

    match args.command:
        case "dark" | "light":
            apply_mode(args.command)
        case "toggle":
            apply_mode("light" if current_mode() == "dark" else "dark")
        case "detect":
            apply_mode(detect_mode())
        case "init":
            init_defaults()
        case "current":
            print(current_mode())
        case "save":
            write_pref(f"{current_mode()}_{args.kind}", args.theme)
        case "clear-light":
            targets = ["shell", "editor"] if args.target == "both" else [args.target]
            for t in targets:
                (STATE_DIR / f"light_{t}").unlink(missing_ok=True)
            print(f"Cleared light variant for {args.target}")
        case _:
            apply_mode(detect_mode())


if __name__ == "__main__":
    main()
