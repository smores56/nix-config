#!/usr/bin/env python3
"""Preview a base16/base24 color scheme for fzf."""

import sys
from pathlib import Path

LABELS = {
    "base00": "bg", "base01": "bg+", "base02": "sel", "base03": "comment",
    "base04": "fg-", "base05": "fg", "base06": "fg+", "base07": "bg++",
    "base08": "red", "base09": "orange", "base0A": "yellow", "base0B": "green",
    "base0C": "cyan", "base0D": "blue", "base0E": "purple", "base0F": "brown",
}


def parse_scheme(path):
    name = variant = ""
    colors = {}
    for line in path.read_text().splitlines():
        stripped = line.strip()
        if stripped.startswith("name:"):
            name = stripped.split('"')[1] if '"' in stripped else stripped.split(":", 1)[1].strip()
        elif stripped.startswith("variant:"):
            variant = stripped.split('"')[1] if '"' in stripped else stripped.split(":", 1)[1].strip()
        elif '"#' in stripped and ":" in stripped:
            key = stripped.split(":")[0].strip()
            hex_val = stripped.split('"#')[1].rstrip('"')
            if len(hex_val) == 6:
                colors[key] = hex_val
    return name, variant, colors


def rgb_swatch(hex_color, label):
    r, g, b = int(hex_color[:2], 16), int(hex_color[2:4], 16), int(hex_color[4:6], 16)
    return f"\033[48;2;{r};{g};{b}m    \033[0m {label:<7s} #{hex_color}"


def main():
    if len(sys.argv) < 2:
        print("Usage: theme-preview.py <scheme-name>", file=sys.stderr)
        sys.exit(1)

    full = sys.argv[1]
    system = full.split("-", 1)[0]
    scheme = full.split("-", 1)[1] if "-" in full else full
    schemes_dir = Path.home() / ".local/share/tinted-theming/tinty/repos/schemes" / system
    scheme_file = schemes_dir / f"{scheme}.yaml"

    if not scheme_file.exists():
        print(f"Scheme not found: {scheme_file}")
        sys.exit(0)

    name, variant, colors = parse_scheme(scheme_file)
    print(f"{name} ({variant})")
    print()

    for base in LABELS:
        if base in colors:
            print(rgb_swatch(colors[base], LABELS[base]))


if __name__ == "__main__":
    main()
