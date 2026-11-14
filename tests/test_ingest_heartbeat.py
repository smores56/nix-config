"""Unit tests for the ingest freshness heartbeat.

The heartbeat is the only freshness signal Kanbei sees. It must carry exactly
the sources the guest consumes: a query channel such as `search` is not an
ingest source, and publishing it quarantined the whole envelope in the guest.
"""

from __future__ import annotations

import importlib
import sys
import unittest
from pathlib import Path

INGEST = Path(__file__).parents[1] / "modules/lib/ingest"


def load(name: str):
    if str(INGEST) not in sys.path:
        sys.path.insert(0, str(INGEST))
    return importlib.import_module(name)


class FreshnessSourcesTests(unittest.TestCase):
    def setUp(self):
        self.heartbeat = load("heartbeat")

    def test_query_only_source_is_not_freshness(self):
        data = {
            "sources": {
                "tuta": {"windowSeconds": 43200},
                "search": {"windowSeconds": 86400, "heartbeat": False},
            },
            "hostSources": {"cluster-digest": {"windowSeconds": 3600}},
        }
        self.assertEqual(
            sorted(self.heartbeat.freshness_sources(data)),
            ["cluster-digest", "tuta"],
        )

    def test_a_source_without_the_flag_stays_in(self):
        data = {"sources": {"finance": {"windowSeconds": 129600}}}
        self.assertEqual(sorted(self.heartbeat.freshness_sources(data)), ["finance"])


if __name__ == "__main__":
    unittest.main()
