"""Unit tests for the kanbei restic freeze refcount.

The bug this guards: with a single "was active" marker, job B's cleanup started the VM
while job A was still snapshotting. The refcount stops the VM only on the first prepare
and starts it only on the last cleanup; a crashed job expires instead of pinning the
guest down forever.
"""

from __future__ import annotations

import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
MODULE = REPO / "modules/lib/kanbei/freeze.py"


def load():
    sys.path.insert(0, str(MODULE.parent))
    spec = importlib.util.spec_from_file_location("kanbei_freeze", MODULE)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class DecideTests(unittest.TestCase):
    def setUp(self):
        self.freeze = load()

    def prepare(self, state, job, now=100, active=True):
        return self.freeze.decide(state, action="prepare", job=job, now=now, active=active)

    def cleanup(self, state, job, now=100):
        return self.freeze.decide(state, action="cleanup", job=job, now=now)

    def test_first_prepare_stops_and_second_does_not(self):
        state, stop, start = self.prepare(self.freeze.empty_state(), "kanbei-r2")
        self.assertTrue(stop)
        self.assertFalse(start)
        state, stop, start = self.prepare(state, "kanbei-local", now=101)
        self.assertFalse(stop)
        self.assertEqual(state["jobs"], {"kanbei-r2": 100, "kanbei-local": 101})

    def test_only_the_last_cleanup_starts_the_vm(self):
        state = self.freeze.empty_state()
        state, _stop, _start = self.prepare(state, "kanbei-r2", now=100)
        state, _stop, _start = self.prepare(state, "kanbei-local", now=101)
        state, _stop, start = self.cleanup(state, "kanbei-local", now=200)
        self.assertFalse(start)
        state, _stop, start = self.cleanup(state, "kanbei-r2", now=201)
        self.assertTrue(start)
        self.assertEqual(state, {"jobs": {}, "was_active": False})

    def test_an_inactive_vm_is_never_started(self):
        state, stop, _start = self.prepare(self.freeze.empty_state(), "kanbei-r2", active=False)
        self.assertFalse(stop)
        _state, _stop, start = self.cleanup(state, "kanbei-r2")
        self.assertFalse(start)

    def test_a_crashed_job_expires_and_is_pruned(self):
        state = {"jobs": {"kanbei-r2": 0}, "was_active": True}
        state, stop, _start = self.prepare(state, "kanbei-local", now=1_000_000)
        self.assertEqual(set(state["jobs"]), {"kanbei-local"})
        self.assertTrue(stop)

    def test_a_cleanup_for_an_unknown_job_leaves_the_other_job_pinned(self):
        state = self.freeze.empty_state()
        state, stop, _start = self.prepare(state, "kanbei-r2", active=True)
        self.assertTrue(stop)
        state, _stop, start = self.cleanup(state, "kanbei-local")
        self.assertFalse(start)
        self.assertEqual(state["jobs"], {"kanbei-r2": 100})


class RunTests(unittest.TestCase):
    def setUp(self):
        self.freeze = load()
        self.dir = tempfile.mkdtemp()
        self.calls = []

    def run_action(self, action, job, active=True):
        return self.freeze.run(
            run_dir=self.dir,
            action=action,
            job=job,
            systemctl="/bin/false",
            unit="microvm@kanbei.service",
            clock=lambda: 1000,
            active=lambda: active,
            stop=lambda: self.calls.append("stop"),
            start=lambda: self.calls.append("start"),
        )

    def test_two_jobs_stop_once_and_start_once(self):
        self.run_action("prepare", "kanbei-r2")
        self.run_action("prepare", "kanbei-local")
        self.assertEqual(self.calls, ["stop"])
        self.run_action("cleanup", "kanbei-r2")
        self.assertEqual(self.calls, ["stop"])
        self.run_action("cleanup", "kanbei-local")
        self.assertEqual(self.calls, ["stop", "start"])
        state = json.loads((Path(self.dir) / self.freeze.STATE_FILE).read_text())
        self.assertEqual(state, {"jobs": {}, "was_active": False})
        self.assertEqual(os.stat(Path(self.dir) / self.freeze.STATE_FILE).st_mode & 0o777, 0o600)

    def test_reset_clears_a_stuck_refcount(self):
        self.run_action("prepare", "kanbei-r2")
        self.assertEqual(self.calls, ["stop"])
        self.run_action("reset", "kanbei-r2")
        self.assertEqual(self.calls, ["stop", "start"])
        state = json.loads((Path(self.dir) / self.freeze.STATE_FILE).read_text())
        self.assertEqual(state, {"jobs": {}, "was_active": False})


if __name__ == "__main__":
    unittest.main()
