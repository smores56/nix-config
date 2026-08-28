import importlib.util
import unittest
from pathlib import Path


def load_sdlc():
    path = Path(__file__).parents[1] / "modules/features/ai/sdlc/sdlc.py"
    spec = importlib.util.spec_from_file_location("sdlc", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class SdlcTests(unittest.TestCase):
    def setUp(self):
        self.s = load_sdlc()

    def task(self, identifier, state_type="unstarted", blocks=(), blocked_by=()):
        return self.s.Task(
            identifier=identifier,
            title=identifier,
            url="",
            state_name="Todo",
            state_type=state_type,
            blocks=blocks,
            blocked_by=blocked_by,
        )

    def blocker(self, identifier, done=False):
        return self.s.Blocker(identifier=identifier, title=identifier, done=done)

    def dag(self, tasks, labels=()):
        return self.s.Dag(
            identifier="FEAT-1",
            title="Feature",
            description="",
            labels=set(labels),
            tasks=tasks,
        )

    def test_has_cycle_detects_cycle(self):
        d = self.dag([
            self.task("A", blocks=("B",)),
            self.task("B", blocks=("A",)),
        ])
        self.assertTrue(d.has_cycle())

    def test_has_cycle_acyclic(self):
        d = self.dag([
            self.task("A", blocks=("B",)),
            self.task("B", blocks=("C",)),
            self.task("C"),
        ])
        self.assertFalse(d.has_cycle())

    def test_workable_excludes_done_tasks(self):
        d = self.dag([self.task("A", "completed"), self.task("B")])
        self.assertEqual([t.identifier for t in d.workable()], ["B"])

    def test_workable_excludes_tasks_with_open_blockers(self):
        d = self.dag([self.task("A"), self.task("B", blocked_by=(self.blocker("A", done=False),))])
        self.assertEqual([t.identifier for t in d.workable()], ["A"])

    def test_workable_includes_tasks_with_done_blockers(self):
        d = self.dag([self.task("A", "completed"), self.task("B", blocked_by=(self.blocker("A", done=True),))])
        self.assertEqual([t.identifier for t in d.workable()], ["B"])

    def test_plan_approved_reflects_label(self):
        self.assertFalse(self.dag([]).plan_approved)
        self.assertTrue(self.dag([], labels=["plan-approved"]).plan_approved)


if __name__ == "__main__":
    unittest.main()