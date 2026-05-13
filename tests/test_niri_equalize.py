import importlib.util
import io
import pathlib
import unittest
from contextlib import redirect_stderr


SCRIPT = pathlib.Path(__file__).parents[1] / "modules" / "desktop" / "niri" / "niri-equalize.py"
SPEC = importlib.util.spec_from_file_location("niri_equalize", SCRIPT)
niri_equalize = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(niri_equalize)


def window(workspace, column, focused=False):
    return {
        "workspace_id": workspace,
        "is_focused": focused,
        "layout": {
            "pos_in_scrolling_layout": [column, 0],
        },
    }


class EqualizeActionsTest(unittest.TestCase):
    def test_empty_window_list(self):
        self.assertEqual(niri_equalize.equalize_actions([]), [])

    def test_missing_focused_window(self):
        self.assertEqual(niri_equalize.equalize_actions([window(1, 0)]), [])

    def test_focused_window_without_layout_position(self):
        windows = [
            {
                "workspace_id": 1,
                "is_focused": True,
                "layout": {},
            }
        ]
        self.assertEqual(niri_equalize.equalize_actions(windows), [])

    def test_focused_window_without_workspace(self):
        windows = [
            {
                "is_focused": True,
                "layout": {
                    "pos_in_scrolling_layout": [0, 0],
                },
            }
        ]
        self.assertEqual(niri_equalize.equalize_actions(windows), [])

    def test_single_column_workspace(self):
        windows = [
            window(1, 0, focused=True),
            window(2, 1),
        ]
        self.assertEqual(niri_equalize.equalize_actions(windows), [])

    def test_multi_column_workspace(self):
        windows = [
            window(1, 2),
            window(1, 0, focused=True),
            window(1, 1),
            window(2, 9),
        ]

        self.assertEqual(
            niri_equalize.equalize_actions(windows),
            [
                ("focus-column", "0"),
                ("set-column-width", "33.3333%"),
                ("focus-column", "1"),
                ("set-column-width", "33.3333%"),
                ("focus-column", "2"),
                ("set-column-width", "33.3333%"),
                ("focus-column", "0"),
                ("center-column",),
            ],
        )

    def test_main_handles_malformed_json(self):
        actions = []
        old_niri_msg = niri_equalize.niri_msg
        old_niri_action = niri_equalize.niri_action
        niri_equalize.niri_msg = lambda *args: "{not-json"
        niri_equalize.niri_action = lambda *args: actions.append(args)
        stderr = io.StringIO()

        try:
            with redirect_stderr(stderr):
                niri_equalize.main()
        finally:
            niri_equalize.niri_msg = old_niri_msg
            niri_equalize.niri_action = old_niri_action

        self.assertEqual(actions, [])
        self.assertIn("invalid JSON", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
