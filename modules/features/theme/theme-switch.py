#!/usr/bin/env python3
"""Switch theme mode (dark/light) and apply matching themes."""

import argparse
import os
import subprocess
import sys
from pathlib import Path

STATE_DIR = Path.home() / ".local/state/theme"
TINTY = os.environ.get("TINTY", "tinty")
THEME_PREVIEW = os.environ.get("THEME_PREVIEW", "theme-preview")
HELIX_PREVIEW = os.environ.get("HELIX_PREVIEW", "helix-preview")
HELIX_THEMES_DIR = os.environ.get("HELIX_THEMES_DIR", "")
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


def ensure_tinty_repos():
    schemes = Path.home() / ".local/share/tinted-theming/tinty/repos/schemes"
    if not schemes.is_dir():
        subprocess.run([TINTY, "install"], capture_output=True)


def fzf_pick(items, header, preview_cmd):
    proc = subprocess.run(
        ["fzf", "--header", header, "--preview", preview_cmd],
        input="\n".join(items), capture_output=True, text=True,
    )
    return proc.stdout.strip() if proc.returncode == 0 else None


def pick_shell():
    ensure_tinty_repos()
    mode = current_mode()
    current = subprocess.run([TINTY, "current"], capture_output=True, text=True).stdout.strip()
    themes = subprocess.run([TINTY, "list"], capture_output=True, text=True).stdout.strip().splitlines()

    choice = fzf_pick(themes, f"Shell theme ({mode}) — current: {current}", f"{THEME_PREVIEW} {{}}")
    if choice:
        subprocess.run([TINTY, "apply", choice])
        write_pref(f"{mode}_shell", choice)


def pick_editor():
    mode = current_mode()

    active_toml = Path.home() / ".config/helix/themes/active.toml"
    current = ""
    if active_toml.exists():
        for line in active_toml.read_text().splitlines():
            if "inherits" in line and '"' in line:
                current = line.split('"')[1]

    themes = sorted(
        p.stem for p in Path(HELIX_THEMES_DIR).glob("*.toml")
    )

    choice = fzf_pick(themes, f"Helix theme ({mode}) — current: {current}", f"{HELIX_PREVIEW} {{}}")
    if choice:
        helix_dir = Path.home() / ".config/helix/themes"
        helix_dir.mkdir(parents=True, exist_ok=True)
        (helix_dir / "active.toml").write_text(f'inherits = "{choice}"\n')
        write_pref(f"{mode}_editor", choice)
        print(f"Helix theme set to {choice} ({mode}) — C-r in helix to reload")


def main():
    parser = argparse.ArgumentParser(description="Switch theme mode and apply matching themes")
    sub = parser.add_subparsers(dest="command")

    sub.add_parser("dark", help="Switch to dark mode")
    sub.add_parser("light", help="Switch to light mode")
    sub.add_parser("toggle", help="Toggle between dark and light")
    sub.add_parser("detect", help="Auto-detect mode from system settings")
    sub.add_parser("init", help="Seed default preferences if missing")
    sub.add_parser("current", help="Print current mode")
    sub.add_parser("shell", help="Pick a shell color scheme for the current mode")
    sub.add_parser("editor", help="Pick a helix theme for the current mode")

    pick_p = sub.add_parser("pick", help="Pick both shell and editor themes")

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
        case "shell":
            pick_shell()
        case "editor":
            pick_editor()
        case "pick":
            pick_shell()
            pick_editor()
        case "save":
            write_pref(f"{current_mode()}_{args.kind}", args.theme)
        case "clear-light":
            targets = ["shell", "editor"] if args.target == "both" else [args.target]
            for t in targets:
                (STATE_DIR / f"light_{t}").unlink(missing_ok=True)
            print(f"Cleared light variant for {args.target}")
        case _:
            parser.print_help()
            sys.exit(1)


if __name__ == "__main__":
    main()
