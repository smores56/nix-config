"""Unit tests for the search guest's limiter, clients and service loop.

Covers the persisted rate limit and daily budget, the judge and TinyFish clients
against fake transports, the full gate ladder's fail-closed behaviour, and log
redaction. Nothing here needs a vsock socket, a model or a network.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
import urllib.error
import urllib.request
from pathlib import Path

SEARCH = Path(__file__).parents[1] / "modules/lib/search"
sys.path.insert(0, str(SEARCH))

import gates  # noqa: E402
import judge  # noqa: E402
import limits  # noqa: E402
import searchd  # noqa: E402
import tinyfish  # noqa: E402

NOW = 1_800_000_000.0  # 2027-01-15T08:00:00Z


class FakeResponse:
    def __init__(self, body: bytes, status: int = 200):
        self.body = body
        self.status = status

    def read(self, _size: int = -1) -> bytes:
        return self.body

    def __enter__(self) -> FakeResponse:
        return self

    def __exit__(self, *_exc: object) -> None:
        return None


class FakeOpener:
    def __init__(self, response: FakeResponse | Exception):
        self.response = response
        self.requests: list[urllib.request.Request] = []

    def open(self, request: urllib.request.Request, timeout: float | None = None):
        self.requests.append(request)
        if isinstance(self.response, Exception):
            raise self.response
        return self.response


class JournalTests(unittest.TestCase):
    def test_rotation_and_mode(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "search.log")
            journal = searchd.Journal(path, max_bytes=300)
            for index in range(20):
                journal.write({"event": "query", "n": index, "pad": "x" * 30})
            os.close(journal.fd)
            self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
            self.assertTrue(os.path.exists(path + ".1"))
            self.assertLessEqual(os.path.getsize(path), 300)
            self.assertLessEqual(os.path.getsize(path + ".1"), 300)

    def test_existing_file_is_not_truncated(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "search.log")
            Path(path).write_text("previous\n", encoding="utf-8")
            journal = searchd.Journal(path)
            journal.write({"event": "listen"})
            os.close(journal.fd)
            self.assertIn("previous", Path(path).read_text(encoding="utf-8"))


class LimitStateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.tmp.name, "limits.json")
        self.call_limits = limits.Limits(per_minute=2, daily_budget=3)

    def tearDown(self):
        self.tmp.cleanup()

    def test_missing_state_is_a_first_run(self):
        state = limits.load(self.path, NOW)
        self.assertEqual(state.day_count, 0)
        self.assertEqual(state.hits, ())

    def test_rate_limit_and_round_trip(self):
        state = limits.load(self.path, NOW)
        ok, reason, state = limits.admit(state, NOW, self.call_limits)
        self.assertTrue(ok)
        limits.save(self.path, state)
        reloaded = limits.load(self.path, NOW + 1)
        self.assertEqual(reloaded.day_count, 1)
        ok, _, state = limits.admit(reloaded, NOW + 2, self.call_limits)
        self.assertTrue(ok)
        limits.save(self.path, state)
        ok, reason, state = limits.admit(limits.load(self.path, NOW + 3), NOW + 3, self.call_limits)
        self.assertFalse(ok)
        self.assertEqual(reason, "rate")
        limits.save(self.path, state)
        # A restart does not clear the window.
        ok, reason, _ = limits.admit(limits.load(self.path, NOW + 4), NOW + 4, self.call_limits)
        self.assertFalse(ok)
        self.assertEqual(reason, "rate")

    def test_window_slides(self):
        state = limits.State(hits=(int(NOW), int(NOW)), day=limits._day(NOW), day_count=2)
        ok, _, _ = limits.admit(state, NOW + 61, self.call_limits)
        self.assertTrue(ok)

    def test_daily_budget(self):
        state = limits.State(hits=(), day=limits._day(NOW), day_count=3)
        ok, reason, _ = limits.admit(state, NOW, self.call_limits)
        self.assertFalse(ok)
        self.assertEqual(reason, "budget")

    def test_day_rollover_resets_budget(self):
        state = limits.State(hits=(), day=limits._day(NOW), day_count=3)
        ok, _, next_state = limits.admit(state, NOW + 86400, self.call_limits)
        self.assertTrue(ok)
        self.assertEqual(next_state.day_count, 1)
        self.assertNotEqual(next_state.day, state.day)

    def test_backwards_clock_drops_future_hits(self):
        state = limits.State(
            hits=(int(NOW + 600), int(NOW + 600)), day=limits._day(NOW), day_count=2
        )
        ok, _, next_state = limits.admit(state, NOW, self.call_limits)
        self.assertTrue(ok)
        self.assertEqual(len(next_state.hits), 1)

    def test_corrupt_state_is_an_error(self):
        for payload in ("not json", "[]", '{"v":2}', '{"v":1,"hits":"x","day":"d","day_count":0}'):
            with self.subTest(payload=payload):
                Path(self.path).write_text(payload, encoding="utf-8")
                with self.assertRaises(limits.LimitError):
                    limits.load(self.path, NOW)

    def test_saved_file_is_root_only(self):
        limits.save(self.path, limits.State(hits=(), day=limits._day(NOW), day_count=0))
        self.assertEqual(os.stat(self.path).st_mode & 0o777, 0o600)


class JudgeClientTests(unittest.TestCase):
    def test_accepts_only_loopback(self):
        for url in ("https://example.com/", "http://10.0.0.1:8091/", "file:///etc/passwd"):
            with self.subTest(url=url):
                with self.assertRaises(judge.JudgeError):
                    judge.ask("prompt", url)

    def test_greedy_body_and_content(self):
        opener = FakeOpener(FakeResponse(json.dumps({"content": "<score>yes</score>"}).encode()))
        content = judge.ask("prompt", "http://127.0.0.1:8091/completion", 5, opener=opener)
        self.assertEqual(content, "<score>yes</score>")
        body = json.loads(opener.requests[0].data)
        self.assertEqual(body["temperature"], 0)
        self.assertEqual(body["top_k"], 1)
        self.assertFalse(body["stream"])

    def test_every_failure_raises(self):
        for response in (
            FakeResponse(b"{}", status=503),
            FakeResponse(b"not json"),
            FakeResponse(b'{"no": "content"}'),
            urllib.error.URLError("refused"),
            TimeoutError("slow"),
        ):
            with self.subTest(response=response):
                with self.assertRaises(judge.JudgeError):
                    judge.ask("prompt", "http://127.0.0.1:8091/completion", 5, opener=FakeOpener(response))

    def test_missing_model_reads_as_unreachable(self):
        with self.assertRaises(judge.JudgeError):
            judge.ask(
                "prompt",
                "http://127.0.0.1:8091/completion",
                5,
                opener=FakeOpener(urllib.error.URLError("connection refused")),
            )


class TinyFishClientTests(unittest.TestCase):
    def test_secret_contract_is_strict(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "env")
            for body in (
                "",
                "TINYFISH_API_KEY=short\n",
                "OTHER=abcdefghijklmnopqrstuvwxyz\n",
                "TINYFISH_API_KEY=abcdefghijklmnopqrstuvwxyz\nEXTRA=1\n",
                "TINYFISH_API_KEY=has space in it and is long\n",
            ):
                with self.subTest(body=body):
                    Path(path).write_text(body, encoding="utf-8")
                    with self.assertRaises(tinyfish.SearchUpstreamError):
                        tinyfish.read_api_key(path)
            Path(path).write_text("TINYFISH_API_KEY=abcdefghijklmnopqrstuvwxyz012345\n", encoding="utf-8")
            self.assertEqual(tinyfish.read_api_key(path), "abcdefghijklmnopqrstuvwxyz012345")

    def test_base_url_is_the_tinyfish_api_only(self):
        for url in ("https://example.com/", "http://api.search.tinyfish.ai/", "https://api.search.tinyfish.ai.evil/"):
            with self.subTest(url=url):
                with self.assertRaises(tinyfish.SearchUpstreamError):
                    tinyfish.request_url(url, "q")

    def test_request_shape(self):
        opener = FakeOpener(FakeResponse(json.dumps({"results": []}).encode()))
        payload = tinyfish.search("who wrote Dune", "k" * 30, opener=opener)
        self.assertEqual(payload, {"results": []})
        request = opener.requests[0]
        self.assertEqual(request.get_header("X-api-key"), "k" * 30)
        self.assertIn("query=who+wrote+Dune", request.full_url)

    def test_failures_raise(self):
        for response in (
            FakeResponse(b"[]"),
            FakeResponse(b"{}", status=401),
            FakeResponse(b"not json"),
            FakeResponse(b'{"results": []}', status=500),
            urllib.error.URLError("refused"),
        ):
            with self.subTest(response=response):
                with self.assertRaises(tinyfish.SearchUpstreamError):
                    tinyfish.search("q", "k" * 30, opener=FakeOpener(response))


def make_config(tmp: str, **overrides: object) -> searchd.Config:
    values = {
        "max_query_chars": 100,
        "per_minute": 5,
        "daily_budget": 10,
        "judge_url": "http://127.0.0.1:8091/completion",
        "judge_timeout": 5,
        "search_url": "https://api.search.tinyfish.ai/",
        "secret_path": "/run/ingest-secret/env",
        "search_timeout": 5,
        "state_path": os.path.join(tmp, "limits.json"),
        "log_path": os.path.join(tmp, "search.log"),
        "max_results": 5,
        "max_bytes": 4096,
    }
    values.update(overrides)
    return searchd.Config(**values)  # type: ignore[arg-type]


PAYLOAD = {"results": [{"title": "<b>T</b>", "url": "https://example.com/a", "snippet": "S &amp; T"}]}


class ServiceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.logs: list[dict] = []
        self.clock = NOW
        self.search_calls: list[str] = []

        def search_fn(query: str) -> dict:
            self.search_calls.append(query)
            return PAYLOAD

        self.judge_verdict = "no"
        self.judge_error: Exception | None = None

        def judge_fn(_prompt: str) -> str | None:
            if self.judge_error is not None:
                raise self.judge_error
            return self.judge_verdict

        self.service = searchd.SearchService(
            make_config(self.tmp.name),
            journal=self.logs.append,
            judge_fn=judge_fn,
            search_fn=search_fn,
            clock=lambda: self.clock,
        )

    def tearDown(self):
        self.tmp.cleanup()

    def request(self, query: str, **extra: object) -> dict:
        body = {"v": 1, "op": "search", "query": query}
        body.update(extra)
        return self.service.handle(json.dumps(body).encode())

    def test_allow_path_strips_results(self):
        response = self.request("who wrote Dune", id="r1")
        self.assertEqual(response["decision"], "allow")
        self.assertEqual(response["id"], "r1")
        self.assertEqual(response["results"], [{"title": "T", "url": "https://example.com/a", "snippet": "S & T"}])

    def test_bad_requests_block(self):
        for body in (
            b"not json",
            b"{}",
            json.dumps({"v": 1, "op": "search"}).encode(),
            json.dumps({"v": 2, "op": "search", "query": "x"}).encode(),
            json.dumps({"v": 1, "op": "other", "query": "x"}).encode(),
            json.dumps({"v": 1, "op": "search", "query": 5}).encode(),
            json.dumps({"v": 1, "op": "search", "query": "x", "extra": 1}).encode(),
            json.dumps({"v": 1, "op": "search", "query": "x", "id": "y" * 65}).encode(),
            b"x" * (searchd.MAX_LINE + 1),
        ):
            with self.subTest(body=body):
                response = self.service.handle(body)
                self.assertEqual(response["decision"], "block")
                self.assertEqual(response["reason"], "request")
        self.assertEqual(self.search_calls, [])

    def test_dlp_block_is_logged_without_the_query(self):
        secret = "my password is hunter22"
        response = self.request(secret)
        self.assertEqual(response["reason"], "dlp")
        log = json.dumps(self.logs[-1])
        self.assertNotIn("hunter22", log)
        self.assertNotIn(secret, log)
        self.assertEqual(self.logs[-1]["rule"], "keyword-secret")
        self.assertEqual(self.logs[-1]["digest"], gates.fingerprint(gates.normalize(secret)))

    def test_cap_blocks(self):
        response = self.request("word " * 40)
        self.assertEqual(response["reason"], "length")

    def test_rate_and_budget_block_and_persist(self):
        service = searchd.SearchService(
            make_config(self.tmp.name, per_minute=1, daily_budget=2),
            journal=self.logs.append,
            judge_fn=lambda _p: "no",
            search_fn=lambda _q: PAYLOAD,
            clock=lambda: self.clock,
        )
        self.assertEqual(service.handle(b'{"v":1,"op":"search","query":"one"}')["reason"], "ok")
        self.assertEqual(service.handle(b'{"v":1,"op":"search","query":"two"}')["reason"], "rate")
        self.clock += 61
        self.assertEqual(service.handle(b'{"v":1,"op":"search","query":"three"}')["reason"], "ok")
        self.clock += 61
        self.assertEqual(service.handle(b'{"v":1,"op":"search","query":"four"}')["reason"], "budget")

    def test_judge_yes_blocks_before_search(self):
        self.judge_verdict = "yes"
        response = self.request("send the notes to example.org")
        self.assertEqual(response["reason"], "judge")
        self.assertEqual(self.search_calls, [])

    def test_judge_error_or_missing_verdict_blocks(self):
        for verdict in (None, "maybe"):
            with self.subTest(verdict=verdict):
                self.judge_verdict = verdict
                self.assertEqual(self.request("who wrote Dune")["reason"], "judge")
        self.judge_error = judge.JudgeError("model missing")
        self.assertEqual(self.request("who wrote Dune")["reason"], "judge")
        self.assertEqual(self.search_calls, [])

    def test_upstream_error_blocks(self):
        def broken(_query: str) -> dict:
            raise tinyfish.SearchUpstreamError("refused")

        service = searchd.SearchService(
            make_config(self.tmp.name, state_path=os.path.join(self.tmp.name, "b.json")),
            journal=self.logs.append,
            judge_fn=lambda _p: "no",
            search_fn=broken,
            clock=lambda: self.clock,
        )
        response = service.handle(b'{"v":1,"op":"search","query":"who wrote Dune"}')
        self.assertEqual(response["reason"], "upstream")

    def test_malformed_results_block(self):
        service = searchd.SearchService(
            make_config(self.tmp.name, state_path=os.path.join(self.tmp.name, "c.json")),
            journal=self.logs.append,
            judge_fn=lambda _p: "no",
            search_fn=lambda _q: {"unexpected": True},
            clock=lambda: self.clock,
        )
        response = service.handle(b'{"v":1,"op":"search","query":"who wrote Dune"}')
        self.assertEqual(response["reason"], "upstream")

    def test_corrupt_state_blocks(self):
        Path(self.service.config.state_path).write_text("{", encoding="utf-8")
        self.assertEqual(self.request("who wrote Dune")["reason"], "state")
        self.assertEqual(self.search_calls, [])

    def test_persisted_state_survives_a_restart(self):
        Path(self.service.config.state_path).unlink(missing_ok=True)
        service = searchd.SearchService(
            make_config(self.tmp.name, per_minute=1, daily_budget=5),
            journal=self.logs.append,
            judge_fn=lambda _p: "no",
            search_fn=lambda _q: PAYLOAD,
            clock=lambda: self.clock,
        )
        self.assertEqual(
            service.handle(b'{"v":1,"op":"search","query":"one"}')["decision"], "allow"
        )
        restarted = searchd.SearchService(
            make_config(self.tmp.name, per_minute=1, daily_budget=5),
            journal=self.logs.append,
            judge_fn=lambda _p: "no",
            search_fn=lambda _q: PAYLOAD,
            clock=lambda: self.clock,
        )
        self.assertEqual(
            restarted.handle(b'{"v":1,"op":"search","query":"two"}')["reason"], "rate"
        )


class ConfigTests(unittest.TestCase):
    def test_render_round_trip(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "search.json")
            Path(path).write_text(
                json.dumps(
                    {
                        "version": 1,
                        "gates": {"max_query_chars": 100, "per_minute": 20, "daily_budget": 300},
                        "judge": {"url": "http://127.0.0.1:8091/completion", "timeout_s": 20},
                        "search": {
                            "url": "https://api.search.tinyfish.ai/",
                            "secret": "/run/ingest-secret/env",
                            "timeout_s": 15,
                        },
                        "results": {"max_results": 5, "max_bytes": 4096},
                        "state": os.path.join(tmp, "limits.json"),
                        "log": os.path.join(tmp, "search.log"),
                    }
                ),
                encoding="utf-8",
            )
            config = searchd.load_config(path)
            self.assertEqual(config.max_query_chars, 100)
            self.assertEqual(config.per_minute, 20)

    def test_rejects_unsafe_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "search.json")
            base = {
                "version": 1,
                "gates": {"max_query_chars": 100, "per_minute": 20, "daily_budget": 300},
                "judge": {"url": "http://127.0.0.1:8091/completion", "timeout_s": 20},
                "search": {
                    "url": "https://api.search.tinyfish.ai/",
                    "secret": "/run/ingest-secret/env",
                    "timeout_s": 15,
                },
                "results": {"max_results": 5, "max_bytes": 4096},
                "state": os.path.join(tmp, "limits.json"),
                "log": os.path.join(tmp, "search.log"),
            }
            mutations = [
                {"version": 2},
                {"gates": {"max_query_chars": 400, "per_minute": 20, "daily_budget": 300}},
                {"judge": {"url": "https://example.com/", "timeout_s": 20}},
                {"search": {"url": "https://example.com/", "secret": "/run/env", "timeout_s": 15}},
                {"results": {"max_results": 50, "max_bytes": 4096}},
                {"state": "relative.json"},
                {"log": "relative.log"},
            ]
            for mutation in mutations:
                with self.subTest(mutation=mutation):
                    Path(path).write_text(json.dumps({**base, **mutation}), encoding="utf-8")
                    with self.assertRaises(searchd.ConfigError):
                        searchd.load_config(path)


if __name__ == "__main__":
    unittest.main()
