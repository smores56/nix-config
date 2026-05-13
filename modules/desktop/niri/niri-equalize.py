#!/usr/bin/env python3
"""Equalize column widths on the focused niri workspace."""

import json
import subprocess
import sys


def equalize_actions(windows):
    focused = next((w for w in windows if w.get("is_focused")), None)
    if not focused:
        return []

    focused_pos = focused.get("layout", {}).get("pos_in_scrolling_layout")
    if focused_pos is None:
        return []

    workspace_id = focused.get("workspace_id")
    if workspace_id is None:
        return []

    columns = {
        w["layout"]["pos_in_scrolling_layout"][0]
        for w in windows
        if w.get("workspace_id") == workspace_id
        and w.get("layout", {}).get("pos_in_scrolling_layout") is not None
    }

    if len(columns) < 2:
        return []

    focused_col = focused_pos[0]
    proportion = f"{100 / len(columns):.4f}%"
    actions = []

    for col in sorted(columns):
        actions.append(("focus-column", str(col)))
        actions.append(("set-column-width", proportion))

    actions.append(("focus-column", str(focused_col)))
    actions.append(("center-column",))
    return actions


def niri_msg(*args):
    try:
        result = subprocess.run(["niri", "msg", "--json", *args], capture_output=True, text=True, timeout=5)
    except subprocess.TimeoutExpired:
        print(f"niri msg {' '.join(args)} timed out", file=sys.stderr)
        return None
    if result.returncode != 0:
        print(f"niri msg {' '.join(args)} failed: {result.stderr}", file=sys.stderr)
        return None
    return result.stdout


def niri_action(*args):
    try:
        result = subprocess.run(["niri", "msg", "action", *args], capture_output=True, text=True, timeout=5)
    except subprocess.TimeoutExpired:
        print(f"niri action {' '.join(args)} timed out", file=sys.stderr)
        return
    if result.returncode != 0:
        print(f"niri action {' '.join(args)} failed: {result.stderr}", file=sys.stderr)


def main():
    raw = niri_msg("windows")
    if not raw:
        return

    try:
        windows = json.loads(raw)
    except json.JSONDecodeError as error:
        print(f"niri windows returned invalid JSON: {error}", file=sys.stderr)
        return

    for action in equalize_actions(windows):
        niri_action(*action)


if __name__ == "__main__":
    main()
