import importlib.util
import unittest
from pathlib import Path


def load_module():
    path = Path(__file__).parents[1] / "modules/lib/agent_view.py"
    spec = importlib.util.spec_from_file_location("agent_view", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


PLAN = {
    "shares": [
        {"rel": "repos", "mode": "rw", "tag": "repos-aaaaaa"},
        {"rel": ".config/git", "mode": "ro", "tag": "config_git-bbbbbb"},
        {"rel": ".local/state/maki/x", "mode": "rw", "tag": "x-cccccc"},
    ],
    "copies": [".zsh_history", ".config/starship.toml"],
}


class ViewOpsTests(unittest.TestCase):
    def setUp(self):
        self.av = load_module()
        self.ops = self.av.view_ops(PLAN)

    def of(self, kind):
        return [op for op in self.ops if isinstance(op, kind)]

    def test_root_and_every_ancestor_become_dirs(self):
        dirs = [op.rel for op in self.of(self.av.Dir)]
        self.assertEqual(dirs[0], "")
        self.assertEqual(
            set(dirs), {"", ".config", ".local", ".local/state", ".local/state/maki"}
        )

    def test_dirs_precede_their_children(self):
        index = {}
        for i, op in enumerate(self.ops):
            index.setdefault(op.rel, i)
        for op in self.ops:
            parent = op.rel.rpartition("/")[0] if "/" in op.rel else ""
            if op.rel:
                self.assertLess(index[parent], index[op.rel], op)

    def test_share_modes_map_to_read_only_binds(self):
        binds = {op.rel: op for op in self.of(self.av.Bind)}
        self.assertFalse(binds["repos"].read_only)
        self.assertTrue(binds[".config/git"].read_only)
        self.assertTrue(binds["repos"].is_dir)

    def test_copies_are_read_only_file_binds(self):
        binds = {op.rel: op for op in self.of(self.av.Bind)}
        for rel in PLAN["copies"]:
            self.assertTrue(binds[rel].read_only)
            self.assertFalse(binds[rel].is_dir)

    def test_every_planned_path_appears_once(self):
        rels = [op.rel for op in self.ops if not isinstance(op, self.av.Dir)]
        self.assertEqual(len(rels), len(set(rels)))
        planned = {s["rel"] for s in PLAN["shares"]} | set(PLAN["copies"])
        self.assertEqual(set(rels), planned)

    def test_rejects_escaping_paths(self):
        for rel in ["../etc", "/etc", "a/../../b", ""]:
            with self.assertRaises(ValueError, msg=rel):
                self.av.view_ops(
                    {"shares": [{"rel": rel, "mode": "ro", "tag": "t"}]}
                )

    def test_rejects_unknown_mode(self):
        with self.assertRaises(ValueError):
            self.av.view_ops({"shares": [{"rel": "a", "mode": "rwx", "tag": "t"}]})


if __name__ == "__main__":
    unittest.main()
