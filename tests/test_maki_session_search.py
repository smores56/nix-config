import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


def load_module():
    path = Path(__file__).parents[1] / "modules/features/ai/maki/maki-session-search.py"
    spec = importlib.util.spec_from_file_location("maki_session_search", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class MakiSessionSearchTests(unittest.TestCase):
    def setUp(self):
        self.search = load_module()

    def write_session(self, directory):
        path = Path(directory) / "session-1.jsonl"
        records = [
            {"t": "header", "v": 2, "id": "session-1", "cwd": "/work/example", "created_at": 10},
            {"t": "msg", "d": {"role": "user", "content": [{"type": "text", "text": "Find parser regression"}]}},
            {
                "t": "msg",
                "d": {
                    "role": "assistant",
                    "content": [
                        {"type": "thinking", "thinking": "ignored"},
                        {"type": "text", "text": "The parser regression is fixed."},
                    ],
                },
            },
            {"t": "out", "id": "call-1", "d": {"Plain": {"text": "tool output is excluded"}}},
            {"t": "meta", "title": "Fix parser", "updated_at": 20, "token_usage": {}},
        ]
        path.write_text("\n".join(json.dumps(record) for record in records) + "\n")
        return path

    def test_load_session_extracts_text_messages_and_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            session = self.search.load_session(self.write_session(directory))

        self.assertEqual(session.id, "session-1")
        self.assertEqual(session.cwd, "/work/example")
        self.assertEqual(session.title, "Fix parser")
        self.assertEqual(session.updated_at, 20)
        self.assertEqual(session.messages, ["Find parser regression", "The parser regression is fixed."])

    def test_format_entry_keeps_searchable_messages_out_of_display(self):
        with tempfile.TemporaryDirectory() as directory:
            session = self.search.load_session(self.write_session(directory))

        entry = self.search.format_entry(session)
        session_id, display = entry.split(" ", maxsplit=1)
        self.assertEqual(session_id, "session-1")
        self.assertIn("Fix parser · /work/example · 1970-01-01 00:00", display)
        self.assertIn("Find parser regression", display)
        self.assertNotIn("tool output", entry)

    def test_format_entry_normalizes_newlines(self):
        with tempfile.TemporaryDirectory() as directory:
            session = self.search.load_session(self.write_session(directory))

        entry = self.search.format_entry(session._replace(title="Fix\nparser", messages=["line one\nline two"]))
        self.assertNotIn("\n", entry)
        self.assertIn("Fix parser", entry)
        self.assertIn("line one line two", entry)


if __name__ == "__main__":
    unittest.main()
