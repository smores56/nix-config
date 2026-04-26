#!/usr/bin/env python3
"""Preview a helix theme's palette for fzf."""

import sys
import tomllib
from pathlib import Path


def rgb_swatch(hex_color, label):
    r, g, b = int(hex_color[:2], 16), int(hex_color[2:4], 16), int(hex_color[4:6], 16)
    return f"\033[48;2;{r};{g};{b}m    \033[0m {label:<20s} #{hex_color}"


def load_theme(themes_dir, name):
    path = themes_dir / f"{name}.toml"
    if not path.exists():
        return {}, None
    with open(path, "rb") as f:
        return tomllib.load(f), path


def extract_palette(themes_dir, name):
    data, _ = load_theme(themes_dir, name)
    if not data:
        return {}, None

    inherits = data.get("inherits")
    palette = {}
    if inherits:
        parent_data, _ = load_theme(themes_dir, inherits)
        palette.update(parent_data.get("palette", {}))
    palette.update(data.get("palette", {}))
    return palette, inherits


def find_bg(themes_dir, name):
    data, _ = load_theme(themes_dir, name)
    if not data:
        return None

    ui_bg = data.get("ui.background")
    if isinstance(ui_bg, dict) and "bg" in ui_bg:
        return ui_bg["bg"]

    inherits = data.get("inherits")
    if inherits:
        parent_data, _ = load_theme(themes_dir, inherits)
        ui_bg = parent_data.get("ui.background")
        if isinstance(ui_bg, dict) and "bg" in ui_bg:
            return ui_bg["bg"]

    return None


def resolve_color(palette, ref):
    if not ref:
        return None
    if ref.startswith("#") and len(ref) == 7:
        return ref[1:]
    color = palette.get(ref, "")
    if color.startswith("#") and len(color) == 7:
        return color[1:]
    return None


def main():
    if len(sys.argv) < 3:
        print("Usage: helix-preview.py <themes-dir> <theme-name>", file=sys.stderr)
        sys.exit(1)

    themes_dir = Path(sys.argv[1])
    name = sys.argv[2]

    palette, inherits = extract_palette(themes_dir, name)

    print(name)
    if inherits:
        print(f"  inherits {inherits}")

    bg_ref = find_bg(themes_dir, name)
    if bg_ref is None:
        print("  \033[7m  transparent  \033[0m")
    else:
        bg_hex = resolve_color(palette, bg_ref)
        if bg_hex and len(bg_hex) == 6:
            print(f"  {rgb_swatch(bg_hex, 'bg')}")

    print()

    if not palette:
        print("  (uses terminal colors)")
        return

    for key in sorted(palette):
        val = palette[key]
        if isinstance(val, str) and val.startswith("#") and len(val) == 7:
            print(rgb_swatch(val[1:], key))


if __name__ == "__main__":
    main()
