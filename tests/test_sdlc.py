import importlib.util
import unittest
from pathlib import Path


def load_sdlc():
    path = Path(__file__).parents[1] / "modules/features/ai/sdlc/sdlc.py"
    spec = importlib.util.spec_from_file_location("sdlc", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def state(name, type_):
    return {"name": name, "type": type_}


def child(identifier, state_, relations=None, inverse=None):
    return {
        "identifier": identifier,
        "title": identifier,
        "url": None,
        "state": state_,
        "relations": {"nodes": relations or []},
        "inverseRelations": {"nodes": inverse or []},
    }


def blocks(dst):
    return {"type": "blocks", "relatedIssue": {"identifier": dst}}


def parent(children, labels):
    return {
        "identifier": "FEAT-1",
        "title": "Feature",
        "description": "",
        "state": state("Ready", "backlog"),
        "labels": {"nodes": [{"name": l} for l in labels]},
        "children": {"nodes": children},
    }


OPEN = state("Todo", "unstarted")
DONE = state("Done", "completed")


class SdlcTests(unittest.TestCase):
    def setUp(self):
        self.s = load_sdlc()

    def test_block_edges_ignores_non_blocks(self):
        children = [
            child("A", OPEN, relations=[blocks("B"), {"type": "related", "relatedIssue": {"identifier": "C"}}]),
            child("B", OPEN),
        ]
        self.assertEqual(self.s.block_edges(children), [("A", "B")])

    def test_has_cycle_detects_cycle(self):
        children = [child("A", OPEN, relations=[blocks("B")]), child("B", OPEN, relations=[blocks("A")])]
        self.assertTrue(self.s.has_cycle(children))

    def test_has_cycle_acyclic(self):
        children = [child("A", OPEN, relations=[blocks("B")]), child("B", OPEN, relations=[blocks("C")]), child("C", OPEN)]
        self.assertFalse(self.s.has_cycle(children))

    def test_workable_requires_plan_approval(self):
        p = parent([child("A", OPEN)], labels=[])
        ready, err = self.s.workable(p, p["children"]["nodes"], {"A": []})
        self.assertIsNone(ready)
        self.assertIn("plan not approved", err)

    def test_workable_requires_terminal_blockers(self):
        p = parent([child("A", OPEN)], labels=["plan-approved"])
        blockers = {"A": [{"done": False}]}
        ready, err = self.s.workable(p, p["children"]["nodes"], blockers)
        self.assertIsNone(ready)
        self.assertIn("no workable tasks", err)

    def test_workable_excludes_done_and_emits_ready(self):
        children = [child("A", DONE), child("B", OPEN)]
        p = parent(children, labels=["plan-approved"])
        ready, _ = self.s.workable(p, children, {"A": [], "B": []})
        self.assertEqual([c["identifier"] for c in ready], ["B"])


if __name__ == "__main__":
    unittest.main()