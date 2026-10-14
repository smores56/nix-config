import importlib.util
import unittest
from pathlib import Path

CHROME = "com.google.Chrome"
KITTY = "net.kovidgoyal.kitty"
SLACK = "com.tinyspeck.slackmacgap"
MAIL = "com.apple.mail"
CALENDAR = "com.apple.iCal"
FINDER = "com.apple.finder"

SPEC = {
    "builtInMonitor": "^built-in",
    "layouts": {
        "docked": {
            "focus": None,
            "workspaces": [
                {"name": "1", "layout": "h_tiles", "children": [CHROME, KITTY]},
                {"name": "2", "layout": "h_tiles", "children": [SLACK, [MAIL, CALENDAR]]},
            ],
        },
        "laptop": {
            "focus": "1",
            "workspaces": [
                {"name": "1", "layout": "h_tiles", "children": [CHROME, KITTY]},
                {"name": "2", "layout": "h_accordion", "children": [SLACK, MAIL, CALENDAR]},
            ],
        },
    },
}


def load_module():
    path = Path(__file__).parents[1] / "modules/desktop/aerospace/aerospace_layout.py"
    spec = importlib.util.spec_from_file_location("aerospace_layout", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeAeroSpace:
    """In-memory AeroSpace: workspaces hold real trees so tests assert the
    resulting arrangement, not the command sequence that produced it."""

    def __init__(self, monitors=("DELL U3425WE", "27E6QCA")):
        self.monitor_names = list(monitors)
        self.roots = {}  # workspace -> {"layout": str, "children": [id | group]}
        self.loose = {}  # id -> (bundle, layout, workspace) for non-tiling windows
        self.bundles = {}  # id -> bundle
        self.focused_id = None
        self.focused_workspace = None
        self.launched = []
        self.pending = {}  # bundle -> [polls_left, id]
        self.next_id = 1000
        # Pinned workspaces live on fixed monitors; others share the first.
        self.home_monitor = {"1": self.monitor_names[0], "2": self.monitor_names[-1]}
        self.visible = {}  # monitor -> workspace shown there
        self.fail_on = set()  # command names that exit non-zero
        self.unlaunchable = set()  # bundles `open -b` cannot find

    # -- setup helpers
    def tile(self, workspace, bundle, window_id=None):
        window_id = window_id or self._new_id()
        self.bundles[window_id] = bundle
        self._root(workspace)["children"].append(window_id)
        return window_id

    def group(self, workspace, layout, *pairs):
        ids = []
        for bundle in pairs:
            window_id = self._new_id()
            self.bundles[window_id] = bundle
            ids.append(window_id)
        self._root(workspace)["children"].append({"layout": layout, "children": ids})
        return ids

    def untiled(self, workspace, bundle, layout):
        window_id = self._new_id()
        self.bundles[window_id] = bundle
        self.loose[window_id] = (bundle, layout, workspace)
        return window_id

    def appears_after_launch(self, bundle, polls):
        self.pending[bundle] = [polls, None]

    def tree(self, workspace):
        def render(node):
            if isinstance(node, int):
                return node
            return (node["layout"], [render(c) for c in node["children"]])

        return render(self._root(workspace))

    # -- client interface used by the module
    def windows(self):
        if "list-windows" in self.fail_on:
            raise self.mod.CommandError("list-windows failed")
        for bundle, entry in list(self.pending.items()):
            entry[0] -= 1
            if entry[0] <= 0 and bundle in self.launched:
                del self.pending[bundle]
                self.tile("3", bundle)
        found = []
        for workspace, root in self.roots.items():
            for window_id, layout in self._walk(root):
                found.append(self.mod.Window(window_id, self.bundles[window_id], layout, workspace))
        for window_id, (bundle, layout, workspace) in self.loose.items():
            # AeroSpace parks minimized windows outside every workspace, so
            # list-windows --all never reports them.
            if layout == "macos_native_minimized":
                continue
            found.append(self.mod.Window(window_id, bundle, layout, workspace))
        return found

    def focused(self):
        return self.focused_id

    def monitors(self):
        return list(self.monitor_names)

    def launch(self, bundle):
        if bundle in self.unlaunchable:
            raise self.mod.CommandError(f"Unable to find application with identifier {bundle}")
        self.launched.append(bundle)

    def run(self, argv):
        cmd, args = argv[0], argv[1:]
        if cmd in self.fail_on:
            raise self.mod.CommandError(f"{cmd} failed")
        handler = getattr(self, "_cmd_" + cmd.replace("-", "_"), None)
        if handler is None:
            raise AssertionError(f"unexpected command {argv}")
        handler(args)

    # -- command semantics (mirroring AeroSpace 0.21.3)
    def _cmd_move_node_to_workspace(self, args):
        window_id, workspace = self._opt(args, "--window-id"), args[-1]
        window_id = int(window_id)
        if window_id in self.loose:
            raise AssertionError(f"moved non-tiling window {window_id}")
        current = self._workspace_of(window_id)
        if current == workspace:
            return
        self._detach(self.roots[current], window_id)
        self._root(workspace)["children"].append(window_id)
        # Without --focus-follows-window, focus stays on the source workspace.
        if window_id == self.focused_id:
            remaining = [w for w, _ in self._walk(self.roots[current])]
            self.focused_id = remaining[0] if remaining else None

    def _cmd_layout(self, args):
        assert "--root" in args, args
        self._root(self._opt(args, "--workspace"))["layout"] = args[-1]

    def _cmd_join_with(self, args):
        window_id = int(self._opt(args, "--window-id"))
        parent = self._parent_of(window_id)
        along = "right" if parent["layout"].startswith("h_") else "down"
        if args[-1] != along:
            raise self.mod.CommandError("No windows in the specified direction")
        i = parent["children"].index(window_id)
        neighbor = parent["children"][i + 1]
        layout = "v_tiles" if parent["layout"].startswith("h_") else "h_tiles"
        parent["children"][i : i + 2] = [{"layout": layout, "children": [window_id, neighbor]}]

    def _cmd_balance_sizes(self, args):
        self._root(self._opt(args, "--workspace"))

    def _cmd_focus(self, args):
        self.focused_id = int(self._opt(args, "--window-id"))
        self.focused_workspace = self._workspace_of(self.focused_id)
        self._show(self.focused_workspace)

    def _cmd_workspace(self, args):
        self.focused_workspace = args[-1]
        self.focused_id = None
        self._show(self.focused_workspace)

    def _show(self, workspace):
        monitor = self.home_monitor.get(workspace, self.monitor_names[0])
        self.visible[monitor] = workspace

    # -- internals
    def _new_id(self):
        self.next_id += 1
        return self.next_id

    def _root(self, workspace):
        return self.roots.setdefault(workspace, {"layout": "h_tiles", "children": []})

    @staticmethod
    def _opt(args, flag):
        return args[args.index(flag) + 1]

    def _walk(self, node):
        for child in node["children"]:
            if isinstance(child, int):
                yield child, node["layout"]
            else:
                yield from self._walk(child)

    def _workspace_of(self, window_id):
        for workspace, root in self.roots.items():
            if any(w == window_id for w, _ in self._walk(root)):
                return workspace
        raise AssertionError(f"unknown window {window_id}")

    def _parent_of(self, window_id, node=None):
        nodes = [node] if node else list(self.roots.values())
        for candidate in nodes:
            if window_id in candidate["children"]:
                return candidate
            for child in candidate["children"]:
                if isinstance(child, dict):
                    found = self._parent_of(window_id, child)
                    if found:
                        return found
        return None

    def _detach(self, root, window_id):
        parent = self._parent_of(window_id, root)
        parent["children"].remove(window_id)
        # AeroSpace normalizes away containers left with one child.
        if parent is not root and len(parent["children"]) == 1:
            grand = self._container_parent(root, parent)
            grand["children"][grand["children"].index(parent)] = parent["children"][0]

    def _container_parent(self, node, target):
        for child in node["children"]:
            if child is target:
                return node
            if isinstance(child, dict):
                found = self._container_parent(child, target)
                if found:
                    return found
        return None


class AeroSpaceLayoutTests(unittest.TestCase):
    def setUp(self):
        self.mod = load_module()
        self.fake = FakeAeroSpace()
        self.fake.mod = self.mod
        self.spec = self.mod.parse_spec(SPEC)

    def arrange(self, mode):
        return self.mod.arrange(self.spec, mode, self.fake, sleep=lambda _: None)

    def scrambled_desk(self):
        f = self.fake
        kitty = f.tile("1", KITTY)
        chrome = f.tile("1", CHROME)
        calendar, mail = f.group("11", "v_tiles", CALENDAR, MAIL)
        slack = f.tile("11", SLACK)
        return {"chrome": chrome, "kitty": kitty, "slack": slack, "mail": mail, "calendar": calendar}

    def test_docked_builds_chrome_kitty_and_slack_beside_mail_over_calendar(self):
        w = self.scrambled_desk()

        problems = self.arrange("docked")

        self.assertEqual(problems, [])
        self.assertEqual(self.fake.tree("1"), ("h_tiles", [w["chrome"], w["kitty"]]))
        self.assertEqual(
            self.fake.tree("2"),
            ("h_tiles", [w["slack"], ("v_tiles", [w["mail"], w["calendar"]])]),
        )

    def test_docked_restores_the_window_focused_before_arranging(self):
        w = self.scrambled_desk()
        self.fake.focused_id = w["mail"]

        self.arrange("docked")

        self.assertEqual(self.fake.focused_id, w["mail"])

    def test_docked_shows_each_layout_workspace_on_its_monitor(self):
        w = self.scrambled_desk()
        self.fake.visible = {"DELL U3425WE": "layout-scratch", "27E6QCA": "11"}
        self.fake.focused_id = w["slack"]

        self.arrange("docked")

        self.assertEqual(self.fake.visible, {"DELL U3425WE": "1", "27E6QCA": "2"})

    def test_laptop_stacks_comms_as_accordion_and_ends_on_workspace_1(self):
        w = self.scrambled_desk()
        self.fake.focused_id = w["mail"]

        self.arrange("laptop")

        self.assertEqual(self.fake.tree("1"), ("h_tiles", [w["chrome"], w["kitty"]]))
        self.assertEqual(self.fake.tree("2"), ("h_accordion", [w["slack"], w["mail"], w["calendar"]]))
        self.assertEqual(self.fake.focused_workspace, "1")

    def test_extra_windows_of_pinned_apps_follow_but_trail_the_arranged_ones(self):
        w = self.scrambled_desk()
        second_chrome = self.fake.tile("4", CHROME)

        self.arrange("docked")

        self.assertEqual(self.fake.tree("1"), ("h_tiles", [w["chrome"], w["kitty"], second_chrome]))

    def test_oldest_window_of_an_app_is_the_one_arranged(self):
        w = self.scrambled_desk()
        newer_mail = self.fake.tile("2", MAIL)

        self.arrange("docked")

        self.assertEqual(
            self.fake.tree("2"),
            ("h_tiles", [w["slack"], ("v_tiles", [w["mail"], w["calendar"]]), newer_mail]),
        )

    def test_minimized_floating_and_fullscreen_windows_are_left_alone(self):
        self.scrambled_desk()
        minimized = self.fake.untiled("5", MAIL, "macos_native_minimized")
        floating = self.fake.untiled("5", SLACK, "floating")
        fullscreen = self.fake.untiled("6", CHROME, "macos_native_fullscreen")

        problems = self.arrange("docked")

        self.assertEqual(problems, [])
        for window_id, workspace in ((minimized, "5"), (floating, "5"), (fullscreen, "6")):
            self.assertEqual(self.fake.loose[window_id][2], workspace)

    def test_unpinned_windows_stay_on_their_workspace(self):
        w = self.scrambled_desk()
        finder = self.fake.tile("1", FINDER)
        elsewhere = self.fake.tile("7", FINDER)

        self.arrange("docked")

        self.assertEqual(self.fake.tree("1"), ("h_tiles", [finder, w["chrome"], w["kitty"]]))
        self.assertEqual(self.fake.tree("7"), ("h_tiles", [elsewhere]))

    def test_missing_app_is_launched_in_background_and_placed_once_its_window_appears(self):
        f = self.fake
        f.tile("1", CHROME)
        f.tile("1", KITTY)
        f.tile("2", MAIL)
        f.tile("2", CALENDAR)
        f.appears_after_launch(SLACK, polls=3)

        problems = self.arrange("docked")

        self.assertEqual(problems, [])
        self.assertEqual(f.launched, [SLACK])
        _, children = f.tree("2")
        self.assertEqual(f.bundles[children[0]], SLACK)

    def test_app_whose_window_never_appears_is_reported_and_the_rest_still_arranged(self):
        f = self.fake
        chrome = f.tile("1", CHROME)
        kitty = f.tile("1", KITTY)
        mail = f.tile("2", MAIL)
        calendar = f.tile("2", CALENDAR)
        clock = iter(range(0, 1000))

        problems = self.mod.arrange(
            self.spec, "docked", f, sleep=lambda _: None, clock=lambda: next(clock)
        )

        self.assertEqual(len(problems), 1)
        self.assertIn(SLACK, problems[0])
        self.assertEqual(f.tree("1"), ("h_tiles", [chrome, kitty]))
        self.assertEqual(f.tree("2"), ("h_tiles", [mail, calendar]))

    def test_app_with_only_a_minimized_window_is_reopened_to_restore_it(self):
        f = self.fake
        f.tile("1", CHROME)
        f.tile("1", KITTY)
        f.tile("2", SLACK)
        f.tile("2", CALENDAR)
        f.untiled("5", MAIL, "macos_native_minimized")
        f.appears_after_launch(MAIL, polls=1)

        problems = self.arrange("docked")

        self.assertEqual(problems, [])
        self.assertEqual(f.launched, [MAIL])

    def test_app_with_only_floating_windows_is_reported_as_not_arranged(self):
        f = self.fake
        f.tile("1", CHROME)
        f.tile("1", KITTY)
        f.tile("2", MAIL)
        f.tile("2", CALENDAR)
        f.untiled("2", SLACK, "floating")

        problems = self.arrange("docked")

        self.assertEqual(f.launched, [])
        self.assertEqual(len(problems), 1)
        self.assertIn(SLACK, problems[0])
        self.assertIn("floating", problems[0])

    def test_launched_app_whose_first_window_floats_is_reported_as_not_arranged(self):
        f = self.fake
        f.tile("1", CHROME)
        f.tile("1", KITTY)
        f.tile("2", SLACK)
        f.tile("2", CALENDAR)
        f.launch = lambda bundle: (f.launched.append(bundle), f.untiled("3", bundle, "floating"))
        clock = iter(range(0, 1000))

        problems = self.mod.arrange(
            self.spec, "docked", f, sleep=lambda _: None, clock=lambda: next(clock)
        )

        self.assertEqual(len(problems), 1)
        self.assertIn(MAIL, problems[0])

    def test_app_that_cannot_be_launched_is_reported_without_waiting(self):
        f = self.fake
        f.tile("1", CHROME)
        f.tile("1", KITTY)
        f.tile("2", MAIL)
        f.tile("2", CALENDAR)
        f.unlaunchable = {SLACK}
        sleeps = []

        problems = self.mod.arrange(self.spec, "docked", f, sleep=sleeps.append)

        self.assertEqual(sleeps, [])
        self.assertEqual(len(problems), 1)
        self.assertIn("launch", problems[0])

    def test_failed_window_listing_is_reported_instead_of_raising(self):
        self.fake.fail_on = {"list-windows"}

        problems = self.arrange("docked")

        self.assertEqual(len(problems), 1)
        self.assertIn("list-windows", problems[0])

    def test_docked_without_a_focused_window_ends_on_the_work_workspace(self):
        self.scrambled_desk()
        self.fake.focused_id = None

        self.arrange("docked")

        self.assertEqual(self.fake.focused_workspace, "1")

    def test_group_under_a_vertical_root_splits_side_by_side(self):
        spec = self.mod.parse_spec(
            {
                "builtInMonitor": "^built-in",
                "layouts": {
                    "docked": {
                        "focus": None,
                        "workspaces": [{"name": "2", "layout": "v_tiles", "children": [SLACK, [MAIL, CALENDAR]]}],
                    },
                    "laptop": {"focus": None, "workspaces": []},
                },
            }
        )
        f = self.fake
        slack = f.tile("2", SLACK)
        mail = f.tile("2", MAIL)
        calendar = f.tile("2", CALENDAR)

        problems = self.mod.arrange(spec, "docked", f, sleep=lambda _: None)

        self.assertEqual(problems, [])
        self.assertEqual(f.tree("2"), ("v_tiles", [slack, ("h_tiles", [mail, calendar])]))

    def test_spec_requires_both_docked_and_laptop_layouts(self):
        bad = {"builtInMonitor": "^built-in", "layouts": {"docked": SPEC["layouts"]["docked"]}}

        with self.assertRaises(ValueError):
            self.mod.parse_spec(bad)

    def test_spec_rejects_focus_on_a_workspace_the_layout_does_not_build(self):
        bad = {
            "builtInMonitor": "^built-in",
            "layouts": {**SPEC["layouts"], "laptop": {**SPEC["layouts"]["laptop"], "focus": "9"}},
        }

        with self.assertRaises(ValueError):
            self.mod.parse_spec(bad)

    def test_spec_rejects_an_app_pinned_twice_in_one_layout(self):
        docked = {
            "focus": None,
            "workspaces": [
                {"name": "1", "layout": "h_tiles", "children": [CHROME, KITTY]},
                {"name": "2", "layout": "h_tiles", "children": [CHROME]},
            ],
        }
        bad = {"builtInMonitor": "^built-in", "layouts": {**SPEC["layouts"], "docked": docked}}

        with self.assertRaises(ValueError):
            self.mod.parse_spec(bad)

    def test_laptop_with_externals_attached_still_shows_both_workspaces(self):
        w = self.scrambled_desk()
        self.fake.visible = {"DELL U3425WE": "11", "27E6QCA": "layout-scratch"}

        self.arrange("laptop")

        self.assertEqual(self.fake.visible, {"DELL U3425WE": "1", "27E6QCA": "2"})
        self.assertEqual(self.fake.focused_workspace, "1")

    def test_unpinned_containers_keep_their_nesting(self):
        w = self.scrambled_desk()
        left, right = self.fake.group("1", "v_tiles", FINDER, FINDER)

        self.arrange("docked")

        self.assertEqual(
            self.fake.tree("1"), ("h_tiles", [("v_tiles", [left, right]), w["chrome"], w["kitty"]])
        )

    def test_group_is_split_when_only_unpinned_windows_share_its_workspace(self):
        f = self.fake
        f.tile("1", CHROME)
        f.tile("1", KITTY)
        finder = f.tile("2", FINDER)
        mail = f.tile("2", MAIL)
        calendar = f.tile("2", CALENDAR)
        clock = iter(range(0, 1000))

        self.mod.arrange(self.spec, "docked", f, sleep=lambda _: None, clock=lambda: next(clock))

        self.assertEqual(f.tree("2"), ("h_tiles", [finder, ("v_tiles", [mail, calendar])]))

    def test_failed_command_is_reported_and_later_commands_still_run(self):
        w = self.scrambled_desk()
        self.fake.fail_on = {"balance-sizes"}

        problems = self.arrange("docked")

        self.assertEqual(len(problems), 2)
        self.assertTrue(all("balance-sizes" in p for p in problems))
        self.assertEqual(self.fake.tree("1"), ("h_tiles", [w["chrome"], w["kitty"]]))

    def test_spec_rejects_a_group_that_is_not_two_apps(self):
        bad = {
            "builtInMonitor": "^built-in",
            "layouts": {
                "docked": {
                    "focus": None,
                    "workspaces": [
                        {"name": "2", "layout": "h_tiles", "children": [[SLACK, MAIL, CALENDAR]]}
                    ],
                },
                "laptop": SPEC["layouts"]["laptop"],
            },
        }

        with self.assertRaises(ValueError):
            self.mod.parse_spec(bad)

    def test_spec_rejects_an_unknown_root_layout(self):
        bad = {
            "builtInMonitor": "^built-in",
            "layouts": {
                "docked": {
                    "focus": None,
                    "workspaces": [{"name": "1", "layout": "tiles", "children": [CHROME]}],
                },
                "laptop": SPEC["layouts"]["laptop"],
            },
        }

        with self.assertRaises(ValueError):
            self.mod.parse_spec(bad)

    def test_window_listing_skips_malformed_lines(self):
        out = "12\tcom.google.Chrome\th_tiles\t1\ngarbage\n13\tcom.apple.mail\tfloating\t2\n"

        windows = self.mod.parse_windows(out)

        self.assertEqual(
            windows,
            [
                self.mod.Window(12, CHROME, "h_tiles", "1"),
                self.mod.Window(13, MAIL, "floating", "2"),
            ],
        )

    def test_second_concurrent_run_cannot_take_the_lock(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "lock"
            with self.mod.single_instance(path) as first:
                with self.mod.single_instance(path) as second:
                    self.assertTrue(first)
                    self.assertFalse(second)

    def test_auto_picks_laptop_when_a_built_in_display_is_present(self):
        self.assertEqual(self.mod.pick_mode(["Built-in Retina Display"], "^built-in"), "laptop")

    def test_auto_picks_docked_with_only_external_monitors(self):
        self.assertEqual(self.mod.pick_mode(["DELL U3425WE", "27E6QCA"], "^built-in"), "docked")


if __name__ == "__main__":
    unittest.main()
