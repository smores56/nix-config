#!/usr/bin/env python3
"""Headless-Chromium proof for the Kanbei shell's no-network rendering rule.

Loads the real shell from the guest server with a planted model reply containing
``![](https://example.com/x.png)`` and ``[click](https://example.com)``, drives the form,
and fails if Chromium tries to fetch anything outside the loopback origin or if the rendered
DOM contains an anchor/image. Traffic is additionally forced to fail DNS for every host but
127.0.0.1, so a regression cannot silently succeed because the sandbox has no network.

CDP runs over ``--remote-debugging-pipe`` (null-terminated JSON on fds 3/4), so this file
is Python stdlib only. Usage:

    nix run nixpkgs#chromium -- --version          # or point CHROMIUM at a binary
    python3 tests/kanbei_browser.py --chromium /nix/store/.../bin/chromium

Exit 0 = pass or skip (skip is printed), 1 = fail.
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
UI_DIR = REPO / "modules/lib/kanbei/ui"
PLANTED = (
    "Planted model output follows.\n"
    "![](https://example.com/x.png)\n"
    "[click](https://example.com)\n"
    "Nothing here may be fetched or linked."
)


def load_server_module():
    import importlib.util

    spec = importlib.util.spec_from_file_location("kanbei_ui_server", UI_DIR / "server.py")
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class CDP:
    def __init__(self, read_fd: int, write_fd: int):
        self.read_fd = read_fd
        self.write_fd = write_fd
        self.buffer = b""
        self.next_id = 1
        self.pending: dict[int, dict] = {}
        self.events: list[dict] = []
        self.lock = threading.Lock()
        self.closed = False
        self.reader = threading.Thread(target=self._read_loop, daemon=True)
        self.reader.start()

    def _read_loop(self) -> None:
        while True:
            try:
                chunk = os.read(self.read_fd, 65536)
            except OSError:
                return
            if not chunk:
                return
            self.buffer += chunk
            while b"\0" in self.buffer:
                raw, self.buffer = self.buffer.split(b"\0", 1)
                if not raw:
                    continue
                message = json.loads(raw)
                with self.lock:
                    if "id" in message:
                        self.pending[message["id"]] = message
                    else:
                        self.events.append(message)

    def send(self, method: str, params: dict | None = None, session: str | None = None) -> int:
        message = {"id": self.next_id, "method": method, "params": params or {}}
        if session:
            message["sessionId"] = session
        self.next_id += 1
        os.write(self.write_fd, json.dumps(message).encode() + b"\0")
        return message["id"]

    def wait(self, message_id: int, timeout: float = 30.0) -> dict:
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self.lock:
                if message_id in self.pending:
                    return self.pending.pop(message_id)
            time.sleep(0.01)
        raise TimeoutError(f"CDP call {message_id} did not answer")

    def call(self, method: str, params: dict | None = None, session: str | None = None) -> dict:
        message_id = self.send(method, params, session)
        response = self.wait(message_id)
        if "error" in response:
            raise RuntimeError(f"{method}: {response['error']}")
        return response.get("result", {})

    def evaluate(self, expression: str, session: str) -> dict:
        result = self.call(
            "Runtime.evaluate",
            {"expression": expression, "awaitPromise": True, "returnByValue": True},
            session,
        )
        if "exceptionDetails" in result:
            raise RuntimeError(result["exceptionDetails"].get("text", "evaluation failed"))
        return result.get("result", {})


def spawn_chromium(binary: str, user_data: str):
    to_browser_r, to_browser_w = os.pipe()
    from_browser_r, from_browser_w = os.pipe()
    # Move the child's ends above the target numbers first: os.pipe() may hand out fd 3 or
    # 4, and a later DUP2 in the spawn action list would then read an overwritten fd.
    child_read = fcntl.fcntl(to_browser_r, fcntl.F_DUPFD, 64)
    child_write = fcntl.fcntl(from_browser_w, fcntl.F_DUPFD, 64)
    actions = [
        (os.POSIX_SPAWN_DUP2, child_read, 3),
        (os.POSIX_SPAWN_DUP2, child_write, 4),
        (os.POSIX_SPAWN_CLOSE, child_read),
        (os.POSIX_SPAWN_CLOSE, child_write),
    ]
    argv = [
        binary,
        "--headless=new",
        "--no-sandbox",
        "--disable-gpu",
        "--disable-dev-shm-usage",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-background-networking",
        "--disable-component-update",
        "--disable-sync",
        "--disable-default-apps",
        "--metrics-recording-only",
        "--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1",
        "--remote-debugging-pipe",
        f"--user-data-dir={user_data}",
        "about:blank",
    ]
    actions += [
        (os.POSIX_SPAWN_OPEN, 1, os.devnull, os.O_WRONLY, 0o666),
        (os.POSIX_SPAWN_OPEN, 2, os.devnull, os.O_WRONLY, 0o666),
    ]
    pid = os.posix_spawn(
        binary,
        argv,
        os.environ.copy(),
        file_actions=actions,
        setsigdef=[signal.SIGPIPE],
    )
    os.close(child_read)
    os.close(child_write)
    os.close(to_browser_r)
    os.close(from_browser_w)
    return pid, CDP(from_browser_r, to_browser_w)


def wait_for(cdp: CDP, session: str, expression: str, timeout: float = 20.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        result = cdp.evaluate(expression, session)
        if result.get("value"):
            return True
        time.sleep(0.1)
    return False


def run(binary: str) -> int:
    server_module = load_server_module()
    config = server_module.Config(ui_dir=str(UI_DIR), stub_reply=PLANTED)
    server = server_module.make_server(config, listen=("127.0.0.1", 0))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    host, port = server.server_address[:2]
    origin = f"http://{host}:{port}"

    user_data = tempfile.mkdtemp(prefix="kanbei-chromium.")
    pid, cdp = spawn_chromium(binary, user_data)
    failures: list[str] = []
    requests: list[str] = []
    try:
        target = cdp.call("Target.createTarget", {"url": "about:blank"})["targetId"]
        session = cdp.call(
            "Target.attachToTarget", {"targetId": target, "flatten": True}
        )["sessionId"]
        cdp.call("Network.enable", {}, session)
        cdp.call("Page.enable", {}, session)
        cdp.call("Runtime.enable", {}, session)
        cdp.call("Page.navigate", {"url": origin + "/"}, session)
        if not wait_for(
            cdp, session, "document.readyState === 'complete' && !!window.KanbeiShell"
        ):
            failures.append("the shell did not finish loading")

        cdp.evaluate(
            """
(() => {
  const input = document.getElementById("message");
  input.value = "render the planted output";
  document.getElementById("chat-form").dispatchEvent(
    new Event("submit", { bubbles: true, cancelable: true })
  );
  return true;
})()
""",
            session,
        )
        if not wait_for(
            cdp,
            session,
            "!!document.querySelector('.message-kanbei .body') && "
            "document.querySelector('.message-kanbei .body').innerText.length > 0",
        ):
            failures.append("the planted reply did not render")

        dom = cdp.evaluate(
            """
(() => {
  const body = document.querySelector('.message-kanbei .body');
  return {
    text: body ? body.innerText : "",
    links: document.querySelectorAll('a').length,
    images: document.querySelectorAll('img').length,
    embeds: document.querySelectorAll('iframe,object,embed,video,audio,source').length,
    external: [...document.querySelectorAll('script[src],link[href]')]
      .map((node) => node.src || node.href)
      .filter((url) => !url.startsWith(location.origin)),
  };
})()
""",
            session,
        )["value"]

        if "![](https://example.com/x.png)" not in dom["text"]:
            failures.append("the planted image markdown was not shown as literal text")
        if "[click](https://example.com)" not in dom["text"]:
            failures.append("the planted link markdown was not shown as literal text")
        for key in ("links", "images", "embeds"):
            if dom[key]:
                failures.append(f"the rendered transcript contains {dom[key]} {key}")
        if dom["external"]:
            failures.append(f"the shell references external resources: {dom['external']}")

        with cdp.lock:
            requests = [
                event["params"]["request"]["url"]
                for event in cdp.events
                if event.get("method") == "Network.requestWillBeSent"
            ]
        external = [
            url
            for url in requests
            if not url.startswith(origin)
            and not url.startswith("data:")
            and not url.startswith("blob:")
            and not url.startswith("about:")
        ]
        if external:
            failures.append(f"Chromium attempted external requests: {external}")

        if failures:
            for failure in failures:
                print(f"FAIL: {failure}", file=sys.stderr)
            print(f"FAIL: observed requests: {requests}", file=sys.stderr)
            return 1
        print("PASS: shell rendered planted output with zero external requests")
        print(f"PASS: observed requests were loopback only ({len(requests)} total)")
        return 0
    finally:
        try:
            cdp.call("Browser.close", {})
        except (RuntimeError, TimeoutError, OSError):
            pass
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass
        for fd in (cdp.read_fd, cdp.write_fd):
            try:
                os.close(fd)
            except OSError:
                pass
        server.shutdown()
        server.server_close()
        shutil.rmtree(user_data, ignore_errors=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--chromium", default=os.environ.get("CHROMIUM") or shutil.which("chromium"))
    args = parser.parse_args(argv)
    if not args.chromium or not os.access(args.chromium, os.X_OK):
        print("SKIP: no Chromium binary (set CHROMIUM or pass --chromium); the shell's")
        print("      network behaviour is then unproven in this environment.")
        return 0
    return run(args.chromium)


if __name__ == "__main__":
    raise SystemExit(main())
