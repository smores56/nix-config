#!/usr/bin/env python3
"""Equalize column widths on the focused niri workspace."""

import json
import subprocess
import sys


def niri_msg(*args):
    result = subprocess.run(["niri", "msg", "--json", *args], capture_output=True, text=True)
    if result.returncode != 0:
        print(f"niri msg {' '.join(args)} failed: {result.stderr}", file=sys.stderr)
    return result.stdout


def niri_action(*args):
    result = subprocess.run(["niri", "msg", "action", *args], capture_output=True, text=True)
    if result.returncode != 0:
        print(f"niri action {' '.join(args)} failed: {result.stderr}", file=sys.stderr)


def main():
    windows = json.loads(niri_msg("windows"))
    focused = next((w for w in windows if w.get("is_focused")), None)
    if not focused:
        return

    workspace_id = focused["workspace_id"]
    columns = {
        w["layout"]["pos_in_scrolling_layout"][0]
        for w in windows
        if w.get("workspace_id") == workspace_id
        and w.get("layout", {}).get("pos_in_scrolling_layout") is not None
    }

    if len(columns) < 2:
        return

    focused_col = focused["layout"]["pos_in_scrolling_layout"][0]
    proportion = f"{100 // len(columns)}%"

    for col in sorted(columns):
        niri_action("focus-column", str(col))
        niri_action("set-column-width", proportion)

    niri_action("focus-column", str(focused_col))
    niri_action("center-column")


if __name__ == "__main__":
    main()
