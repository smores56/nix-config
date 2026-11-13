"""Unit tests for the Brave ingest path (smores56/sdlc#591).

Covers the History snapshot/cursor/dedupe/batching logic, URL hygiene and
timestamp conversion, plus the profile seed contract (`brave_sync_v2.seed`
planting in Brave's base64-of-the-blob form, `Preferences` preservation, code
staging and redaction). No Brave binary, Xvfb or Sync account is needed.
"""

from __future__ import annotations

import base64
import importlib
import io
import json
import os
import sqlite3
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

INGEST = Path(__file__).parents[1] / "modules/lib/ingest"


def load(name: str):
    if str(INGEST) not in sys.path:
        sys.path.insert(0, str(INGEST))
    module = importlib.import_module(name)
    getattr(module, "_SECRETS", set()).clear()
    return module


def make_history(path: str, visits: list[tuple[int, str, str]]) -> None:
    database = sqlite3.connect(path)
    try:
        database.execute("CREATE TABLE urls (id INTEGER PRIMARY KEY, url TEXT, title TEXT)")
        database.execute("CREATE TABLE visits (id INTEGER PRIMARY KEY, url INTEGER, visit_time INTEGER)")
        for index, (visit_time, url, title) in enumerate(visits, 1):
            database.execute("INSERT INTO urls (id, url, title) VALUES (?, ?, ?)", (index, url, title))
            database.execute("INSERT INTO visits (id, url, visit_time) VALUES (?, ?, ?)", (index, index, visit_time))
        database.commit()
    finally:
        database.close()


class HistoryTests(unittest.TestCase):
    def setUp(self):
        self.brave = load("brave_history")

    def test_webkit_conversion(self):
        self.assertEqual(self.brave.webkit_to_epoch(self.brave.epoch_to_webkit(1700000000)), 1700000000)

    def test_clean_url(self):
        self.assertEqual(self.brave.clean_url("https://example.test/a?q=1#frag"), "https://example.test/a?q=1")
        self.assertEqual(self.brave.clean_url("https://user:pw@example.test/x"), "https://example.test/x")
        self.assertEqual(self.brave.clean_url("chrome://settings"), "")
        self.assertEqual(self.brave.clean_url("file:///etc/passwd"), "")
        self.assertEqual(self.brave.clean_url(""), "")

    def visits(self) -> list[tuple[int, str, str]]:
        base = self.brave.epoch_to_webkit(1700000000)
        return [
            (base + 1, "https://example.test/one", "One"),
            (base + 2, "https://example.test/two", "Two"),
            (base + 3, "chrome://settings", "Settings"),
        ]

    def test_collect_cursor_and_dedupe(self):
        with tempfile.TemporaryDirectory() as directory:
            history = os.path.join(directory, "History")
            make_history(history, self.visits())
            state = self.brave.load_state(os.path.join(directory, "state.json"))
            summary = self.brave.collect(
                history,
                state,
                os.path.join(directory, "outbox"),
                workdir=os.path.join(directory, "work"),
                now=1700001000,
                lookback_hours=96,
            )
            self.assertEqual(summary["scanned"], 3)
            # The whole-database count separates an empty profile from a cursor that
            # is simply past every visit.
            self.assertEqual(summary["db_visits"], 3)
            # chrome:// is scanned (the cursor still advances) but not emitted.
            self.assertEqual(summary["emitted"], 2)
            self.assertEqual(state["visit_time"], self.brave.epoch_to_webkit(1700000000) + 3)
            outbox = os.path.join(directory, "outbox")
            payload = json.loads(Path(outbox, sorted(os.listdir(outbox))[0]).read_text(encoding="utf-8"))
            self.assertEqual(payload["source"], "brave")
            self.assertEqual(payload["kind"], "batch")
            self.assertEqual(payload["items"][0]["type"], "browse")
            self.assertEqual(payload["items"][0]["url"], "https://example.test/one")
            self.assertEqual(payload["items"][0]["visited_at"], "2023-11-14T22:13:20+00:00")
            # Second pass sees the same rows: no new batches, no duplicates.
            summary = self.brave.collect(
                history,
                state,
                outbox,
                workdir=os.path.join(directory, "work"),
                now=1700002000,
                lookback_hours=96,
            )
            self.assertEqual(summary["emitted"], 0)

    def test_new_visit_is_emitted(self):
        with tempfile.TemporaryDirectory() as directory:
            history = os.path.join(directory, "History")
            make_history(history, self.visits()[:2])
            state = self.brave.load_state(os.path.join(directory, "state.json"))
            self.brave.collect(
                history,
                state,
                os.path.join(directory, "outbox"),
                workdir=os.path.join(directory, "work"),
                now=1700001000,
                lookback_hours=96,
            )
            database = sqlite3.connect(history)
            database.execute(
                "INSERT INTO urls (id, url, title) VALUES (9, ?, ?)", ("https://example.test/three", "Three")
            )
            database.execute(
                "INSERT INTO visits (id, url, visit_time) VALUES (9, 9, ?)",
                (self.brave.epoch_to_webkit(1700003000),),
            )
            database.commit()
            database.close()
            summary = self.brave.collect(
                history,
                state,
                os.path.join(directory, "outbox"),
                workdir=os.path.join(directory, "work"),
                now=1700004000,
                lookback_hours=96,
            )
            self.assertEqual(summary["emitted"], 1)

    def test_batching(self):
        with tempfile.TemporaryDirectory() as directory:
            history = os.path.join(directory, "History")
            base = self.brave.epoch_to_webkit(1700000000)
            make_history(
                history,
                [(base + index, f"https://example.test/{index}", f"Title {index}") for index in range(1, 1001)],
            )
            state = self.brave.load_state(os.path.join(directory, "state.json"))
            summary = self.brave.collect(
                history,
                state,
                os.path.join(directory, "outbox"),
                workdir=os.path.join(directory, "work"),
                now=1700001000,
                lookback_hours=96,
            )
            self.assertEqual(summary["emitted"], 1000)
            self.assertEqual(summary["batches"], 3)
            sizes = []
            outbox = os.path.join(directory, "outbox")
            for name in sorted(os.listdir(outbox)):
                sizes.append(len(json.loads(Path(outbox, name).read_text(encoding="utf-8"))["items"]))
            self.assertEqual(sizes, [400, 400, 200])

    def test_missing_history_is_an_error(self):
        state = self.brave.load_state("/nonexistent/state.json")
        with self.assertRaises(self.brave.BraveError):
            self.brave.collect(
                "/nonexistent/History",
                state,
                "/tmp/out",
                workdir="/tmp/work",
                now=1700000000,
            )


class SyncTests(unittest.TestCase):
    def setUp(self):
        self.sync = load("brave_sync")

    def test_seed_planting_preserves_preferences(self):
        inner = base64.b64encode(bytes(16) + b"ciphertext").decode()
        seed = "v10" + inner
        with tempfile.TemporaryDirectory() as directory:
            prefs = os.path.join(directory, "Preferences")
            with open(prefs, "w", encoding="utf-8") as handle:
                json.dump({"profile": {"name": "owner"}, "brave_sync_v2": {"other": 1}}, handle)
            document = self.sync.load_preferences(prefs)
            self.sync.plant(document, seed)
            self.sync.write_preferences(prefs, document)
            reloaded = self.sync.load_preferences(prefs)
            # Brave stores base64 of the raw blob, not the v10… text.
            stored = base64.b64encode(b"v10" + base64.b64decode(inner)).decode()
            self.assertEqual(reloaded["brave_sync_v2"]["seed"], stored)
            self.assertEqual(reloaded["brave_sync_v2"]["other"], 1)
            self.assertEqual(reloaded["profile"]["name"], "owner")
            self.assertEqual(oct(os.stat(prefs).st_mode & 0o777), "0o600")
            self.assertEqual(self.sync.status(prefs)["seed_present"], True)
            self.assertEqual(self.sync.status(prefs)["seed_shape"], "oscrypt")

    def test_status_reads_the_legacy_location(self):
        with tempfile.TemporaryDirectory() as directory:
            prefs = os.path.join(directory, "Preferences")
            with open(prefs, "w", encoding="utf-8") as handle:
                json.dump({"brave_sync": {"v2": {"seed": "v10abc"}}}, handle)
            self.assertEqual(self.sync.status(prefs)["seed_present"], True)

    def test_plant_refuses_a_non_blob_seed(self):
        with self.assertRaises(self.sync.SyncError):
            self.sync.plant({}, "v10not-base64!!")

    def test_seed_validation(self):
        self.assertEqual(self.sync.validate_seed('"quoted"'), "quoted")
        with self.assertRaises(self.sync.SyncError):
            self.sync.validate_seed('"unterminated')
        with self.assertRaises(self.sync.SyncError):
            self.sync.validate_seed("line\nbreak")
        with self.assertRaises(self.sync.SyncError):
            self.sync.validate_seed("x" * (self.sync.MAX_SEED_BYTES + 1))

    def test_stage_reads_env_and_stages_code(self):
        with tempfile.TemporaryDirectory() as directory:
            env = os.path.join(directory, "env")
            prefs = os.path.join(directory, "Preferences")
            code = os.path.join(directory, "run", "sync-code")
            blob = "v10" + base64.b64encode(bytes(16) + b"ciphertext").decode()
            with open(env, "w", encoding="utf-8") as handle:
                handle.write(f"BRAVE_SYNC_SEED={blob}\nBRAVE_SYNC_CODE=one two three\n")
            summary = self.sync.stage(env, prefs, code)
            self.assertTrue(summary["planted"])
            self.assertTrue(summary["code_staged"])
            self.assertEqual(oct(os.stat(code).st_mode & 0o777), "0o600")
            with open(code, encoding="utf-8") as handle:
                self.assertEqual(handle.read(), "one two three")

    def test_missing_env_is_a_noop(self):
        with tempfile.TemporaryDirectory() as directory:
            summary = self.sync.stage(os.path.join(directory, "absent"), os.path.join(directory, "Preferences"))
            self.assertFalse(summary["seed_present"])
            self.assertFalse(summary["planted"])

    def test_unknown_keys_are_refused(self):
        with self.assertRaises(self.sync.SyncError):
            self.sync.parse_env("BRAVE_SYNC_SEED=x\nBRAVE_PASSWORD=y\n")

    def test_log_redaction(self):
        self.sync.register_secrets("v10seed", "one two three")
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            self.sync.log("seed", seed_present=True, detail="v10seed one two three")
        output = buffer.getvalue()
        self.assertNotIn("v10seed", output)
        self.assertNotIn("one two three", output)


if __name__ == "__main__":
    unittest.main()
