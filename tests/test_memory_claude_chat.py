import asyncio
import json
import os
import stat
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).parents[1] / "modules/features/ai/memory/src"))

import httpx  # noqa: E402

from memory_mcp import claude_chat  # noqa: E402
from memory_mcp.llm_proxy import create_app  # noqa: E402

FAKE_CLAUDE = textwrap.dedent(
    """\
    #!{python}
    import json, os, sys, time, uuid

    log = os.environ["FAKE_CLAUDE_DIR"]
    mode = os.environ.get("FAKE_CLAUDE_MODE", "ok")
    stdin = sys.stdin.read()
    with open(os.path.join(log, "call-" + uuid.uuid4().hex + ".json"), "w") as handle:
        json.dump({{"argv": sys.argv[1:], "stdin": stdin, "env": dict(os.environ), "pid": os.getpid()}}, handle)

    running = os.path.join(log, "running")
    os.makedirs(running, exist_ok=True)
    marker = os.path.join(running, str(os.getpid()))
    open(marker, "w").close()
    with open(os.path.join(log, "peak"), "a") as handle:
        handle.write(str(len(os.listdir(running))) + "\\n")
    time.sleep(float(os.environ.get("FAKE_CLAUDE_DELAY", "0")))
    os.remove(marker)

    if mode == "exit1":
        print("boom", file=sys.stderr)
        sys.exit(1)
    if mode == "garbage":
        print("not json")
        sys.exit(0)
    reply = {{
        "type": "result",
        "subtype": "success",
        "is_error": mode == "error",
        "result": "plain answer",
        "usage": {{"input_tokens": 11, "output_tokens": 7}},
    }}
    if "--json-schema" in sys.argv and mode != "no-structured":
        reply["structured_output"] = {{"entities": ["a", "b"]}}
    print(json.dumps(reply))
    """
)

SCHEMA = {
    "type": "object",
    "properties": {"entities": {"type": "array", "items": {"type": "string"}}},
    "required": ["entities"],
}


def chat_body(*, schema=None, messages=None, **extra):
    body = {
        "model": "whatever-graphiti-asked-for",
        "messages": messages
        or [
            {"role": "system", "content": "You extract entities."},
            {"role": "user", "content": "Alice met Bob."},
        ],
        **extra,
    }
    if schema is not None:
        body["response_format"] = {
            "type": "json_schema",
            "json_schema": {"name": "extraction", "schema": schema, "strict": True},
        }
    return body


class FakeClaudeCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.binary = self.dir / "claude"
        self.binary.write_text(FAKE_CLAUDE.format(python=sys.executable))
        self.binary.chmod(self.binary.stat().st_mode | stat.S_IXUSR)
        env = mock.patch.dict(
            os.environ, {"FAKE_CLAUDE_DIR": str(self.dir), "FAKE_CLAUDE_MODE": "ok"}
        )
        env.start()
        self.addCleanup(env.stop)
        self.addCleanup(self.tmp.cleanup)

    def calls(self):
        return [json.loads(p.read_text()) for p in sorted(self.dir.glob("call-*.json"))]

    def config(self, **overrides):
        # The fake reads its own knobs from the environment; real runs pass none of these.
        return claude_chat.ClaudeConfig(
            binary=str(self.binary),
            passthrough=("FAKE_CLAUDE_DIR", "FAKE_CLAUDE_MODE", "FAKE_CLAUDE_DELAY"),
            **overrides,
        )


class PureMappingTests(unittest.TestCase):
    def test_system_messages_become_the_system_prompt_and_the_rest_the_prompt(self):
        system, prompt = claude_chat.split_messages(
            [
                {"role": "system", "content": "be terse"},
                {"role": "user", "content": "hello"},
            ]
        )
        self.assertEqual((system, prompt), ("be terse", "hello"))

    def test_a_conversation_keeps_its_roles(self):
        _, prompt = claude_chat.split_messages(
            [
                {"role": "user", "content": "one"},
                {"role": "assistant", "content": "two"},
                {"role": "user", "content": "three"},
            ]
        )
        self.assertEqual(prompt, "user: one\n\nassistant: two\n\nuser: three")

    def test_content_parts_are_joined_as_text(self):
        system, prompt = claude_chat.split_messages(
            [
                {"role": "system", "content": [{"type": "text", "text": "a"}, {"type": "text", "text": "b"}]},
                {"role": "user", "content": [{"type": "text", "text": "q"}]},
            ]
        )
        self.assertEqual((system, prompt), ("a\nb", "q"))

    def test_only_json_schema_formats_carry_a_schema(self):
        self.assertEqual(claude_chat.response_schema(chat_body(schema=SCHEMA)), SCHEMA)
        self.assertIsNone(claude_chat.response_schema(chat_body()))
        self.assertIsNone(claude_chat.response_schema(chat_body(response_format={"type": "json_object"})))

    def test_argv_is_the_locked_down_headless_invocation(self):
        config = claude_chat.ClaudeConfig(binary="/bin/claude", model="claude-haiku-5-5")
        self.assertEqual(
            claude_chat.build_argv(config, "sys", SCHEMA),
            [
                "/bin/claude",
                "-p",
                "--model",
                "claude-haiku-5-5",
                "--system-prompt",
                "sys",
                "--tools",
                "",
                "--strict-mcp-config",
                "--setting-sources",
                "",
                "--no-session-persistence",
                "--output-format",
                "json",
                "--json-schema",
                json.dumps(SCHEMA, separators=(",", ":")),
            ],
        )

    def test_argv_omits_empty_system_prompt_and_absent_schema(self):
        argv = claude_chat.build_argv(claude_chat.ClaudeConfig(binary="c"), "", None)
        self.assertNotIn("--system-prompt", argv)
        self.assertNotIn("--json-schema", argv)

    def test_the_default_model_is_haiku(self):
        self.assertEqual(claude_chat.ClaudeConfig(binary="c").model, "claude-haiku-5-5")

    def test_binary_resolution_prefers_the_override_then_the_user_install(self):
        self.assertEqual(claude_chat.resolve_binary({"MEMORY_CLAUDE_BIN": "/x/claude"}, home="/h"), "/x/claude")
        self.assertEqual(claude_chat.resolve_binary({}, home="/h"), "/h/.local/bin/claude")


class CompleteTests(FakeClaudeCase, unittest.IsolatedAsyncioTestCase):
    async def test_structured_output_is_the_message_content(self):
        reply = await claude_chat.complete(self.config(model="m1"), chat_body(schema=SCHEMA))

        self.assertEqual(reply["object"], "chat.completion")
        self.assertEqual(reply["model"], "m1")
        message = reply["choices"][0]["message"]
        self.assertEqual(message["role"], "assistant")
        self.assertEqual(json.loads(message["content"]), {"entities": ["a", "b"]})
        self.assertEqual(reply["choices"][0]["finish_reason"], "stop")
        self.assertEqual(reply["usage"], {"prompt_tokens": 11, "completion_tokens": 7, "total_tokens": 18})

    async def test_the_prompt_goes_on_stdin_never_argv(self):
        await claude_chat.complete(self.config(), chat_body(schema=SCHEMA))

        (call,) = self.calls()
        self.assertEqual(call["stdin"], "Alice met Bob.")
        self.assertNotIn("Alice met Bob.", call["argv"])
        self.assertIn("You extract entities.", call["argv"])
        self.assertEqual(call["argv"][call["argv"].index("--json-schema") + 1], json.dumps(SCHEMA, separators=(",", ":")))

    async def test_without_a_schema_the_result_text_is_returned(self):
        reply = await claude_chat.complete(self.config(), chat_body())

        self.assertEqual(reply["choices"][0]["message"]["content"], "plain answer")
        (call,) = self.calls()
        self.assertNotIn("--json-schema", call["argv"])

    async def test_the_requested_model_is_ignored_for_the_configured_one(self):
        await claude_chat.complete(self.config(model="claude-haiku-5-5"), chat_body())

        (call,) = self.calls()
        self.assertEqual(call["argv"][call["argv"].index("--model") + 1], "claude-haiku-5-5")

    async def test_is_error_is_a_claude_error(self):
        os.environ["FAKE_CLAUDE_MODE"] = "error"
        with self.assertRaises(claude_chat.ClaudeError) as raised:
            await claude_chat.complete(self.config(), chat_body())
        self.assertNotIn("plain answer", str(raised.exception))

    async def test_a_nonzero_exit_is_a_claude_error(self):
        os.environ["FAKE_CLAUDE_MODE"] = "exit1"
        with self.assertRaises(claude_chat.ClaudeError) as raised:
            await claude_chat.complete(self.config(), chat_body())
        self.assertIn("exited 1", str(raised.exception))
        self.assertNotIn("boom", str(raised.exception))

    async def test_unparseable_output_is_a_claude_error(self):
        os.environ["FAKE_CLAUDE_MODE"] = "garbage"
        with self.assertRaises(claude_chat.ClaudeError) as raised:
            await claude_chat.complete(self.config(), chat_body())
        self.assertNotIn("not json", str(raised.exception))

    async def test_a_schema_without_structured_output_is_a_claude_error(self):
        os.environ["FAKE_CLAUDE_MODE"] = "no-structured"
        with self.assertRaises(claude_chat.ClaudeError):
            await claude_chat.complete(self.config(), chat_body(schema=SCHEMA))

    async def test_a_missing_binary_is_a_claude_error(self):
        with self.assertRaisesRegex(claude_chat.ClaudeError, "claude"):
            await claude_chat.complete(claude_chat.ClaudeConfig(binary=str(self.dir / "absent")), chat_body())

    async def test_a_hung_claude_times_out(self):
        os.environ["FAKE_CLAUDE_DELAY"] = "5"
        self.addCleanup(os.environ.pop, "FAKE_CLAUDE_DELAY", None)
        with self.assertRaises(claude_chat.ClaudeTimeout):
            await claude_chat.complete(self.config(timeout=0.3), chat_body())
        (call,) = self.calls()
        self.assertTrue(await self.gone(call["pid"]))

    async def gone(self, pid):
        for _ in range(50):
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return True
            await asyncio.sleep(0.05)
        return False

    async def test_cancellation_kills_the_child(self):
        os.environ["FAKE_CLAUDE_DELAY"] = "5"
        self.addCleanup(os.environ.pop, "FAKE_CLAUDE_DELAY", None)
        task = asyncio.ensure_future(claude_chat.complete(self.config(), chat_body()))
        for _ in range(100):
            if self.calls():
                break
            await asyncio.sleep(0.05)
        (call,) = self.calls()
        task.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await task
        self.assertTrue(await self.gone(call["pid"]))

    async def test_the_child_sees_only_allowlisted_environment(self):
        with mock.patch.dict(os.environ, {"OPENAI_KEY_LIKE": "secret", "HOME": "/h", "LANG": "C"}):
            await claude_chat.complete(self.config(), chat_body())
        (call,) = self.calls()
        self.assertNotIn("OPENAI_KEY_LIKE", call["env"])
        self.assertEqual(call["env"]["HOME"], "/h")
        self.assertEqual(call["env"]["LANG"], "C")

    def test_a_missing_or_non_executable_binary_fails_the_check(self):
        with self.assertRaises(claude_chat.ClaudeError):
            claude_chat.check_binary(claude_chat.ClaudeConfig(binary=str(self.dir / "absent")))
        plain = self.dir / "plain"
        plain.write_text("x")
        with self.assertRaises(claude_chat.ClaudeError):
            claude_chat.check_binary(claude_chat.ClaudeConfig(binary=str(plain)))
        claude_chat.check_binary(self.config())


class ProxyBackendTests(FakeClaudeCase, unittest.IsolatedAsyncioTestCase):
    def app(self, **kwargs):
        self.upstream_seen = []

        def handler(request: httpx.Request) -> httpx.Response:
            self.upstream_seen.append(request)
            return httpx.Response(200, json={"data": [{"embedding": [0.1]}]})

        return create_app(
            upstream="http://upstream",
            transport=httpx.MockTransport(handler),
            api_key="openai-test-key",
            chat_backend="claude",
            claude=self.config(model="claude-haiku-5-5"),
            **kwargs,
        )

    async def post(self, app, path, body):
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://127.0.0.1") as client:
            return await client.post(path, json=body)

    async def test_chat_is_served_by_claude_and_never_reaches_upstream(self):
        reply = await self.post(self.app(), "/v1/chat/completions", chat_body(schema=SCHEMA))

        self.assertEqual(reply.status_code, 200)
        self.assertEqual(json.loads(reply.json()["choices"][0]["message"]["content"]), {"entities": ["a", "b"]})
        self.assertEqual(self.upstream_seen, [])

    async def test_embeddings_still_go_upstream_with_the_key(self):
        reply = await self.post(self.app(), "/v1/embeddings", {"model": "m", "input": "x"})

        self.assertEqual(reply.status_code, 200)
        (request,) = self.upstream_seen
        self.assertEqual(request.url.path, "/v1/embeddings")
        self.assertEqual(request.headers["authorization"], "Bearer openai-test-key")
        self.assertEqual(self.calls(), [])

    async def test_a_claude_failure_is_a_502(self):
        os.environ["FAKE_CLAUDE_MODE"] = "error"
        reply = await self.post(self.app(), "/v1/chat/completions", chat_body())

        self.assertEqual(reply.status_code, 502)
        self.assertEqual(reply.json()["error"]["type"], "claude_failed")

    async def test_a_nonzero_exit_is_a_502(self):
        os.environ["FAKE_CLAUDE_MODE"] = "exit1"
        reply = await self.post(self.app(), "/v1/chat/completions", chat_body())

        self.assertEqual(reply.status_code, 502)

    async def test_a_timeout_is_a_504(self):
        os.environ["FAKE_CLAUDE_DELAY"] = "5"
        self.addCleanup(os.environ.pop, "FAKE_CLAUDE_DELAY", None)
        app = create_app(
            upstream="http://upstream",
            transport=httpx.MockTransport(lambda r: httpx.Response(200, json={})),
            api_key="k",
            chat_backend="claude",
            claude=self.config(timeout=0.3),
        )
        reply = await self.post(app, "/v1/chat/completions", chat_body())

        self.assertEqual(reply.status_code, 504)

    async def test_concurrency_is_capped_at_two_by_default(self):
        os.environ["FAKE_CLAUDE_DELAY"] = "0.4"
        self.addCleanup(os.environ.pop, "FAKE_CLAUDE_DELAY", None)
        app = self.app()
        self.assertEqual(app.state.upstream_concurrency, 2)

        import asyncio

        replies = await asyncio.gather(*(self.post(app, "/v1/chat/completions", chat_body()) for _ in range(5)))

        self.assertTrue(all(r.status_code == 200 for r in replies))
        peaks = [int(line) for line in (self.dir / "peak").read_text().split()]
        self.assertEqual(max(peaks), 2)
        self.assertEqual(len(peaks), 5)

    async def test_reasoning_effort_is_not_rewritten_on_this_path(self):
        reply = await self.post(self.app(), "/v1/chat/completions", chat_body())

        self.assertEqual(reply.status_code, 200)
        (call,) = self.calls()
        self.assertNotIn("reasoning_effort", " ".join(call["argv"]))

    def test_the_proxy_refuses_to_start_without_an_executable_claude(self):
        with self.assertRaises(claude_chat.ClaudeError):
            create_app(
                upstream="http://upstream",
                api_key="k",
                chat_backend="claude",
                claude=claude_chat.ClaudeConfig(binary=str(self.dir / "absent")),
            )

    async def test_a_non_object_body_is_a_400(self):
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=self.app()), base_url="http://127.0.0.1") as client:
            reply = await client.post("/v1/chat/completions", content=b"[1]")

        self.assertEqual(reply.status_code, 400)


if __name__ == "__main__":
    unittest.main()
