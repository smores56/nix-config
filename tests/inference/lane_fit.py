#!/usr/bin/env python3
"""Lane-fit check: four concurrent requests at 128k + 32k + 32k + 32k tokens.

The chat lane serves one unified q8_0 KV pool, so the four nominal sizes do not all fit at
once (229,376 > 163,840). The check therefore asks for a pass on:

  PASS: every lane returns HTTP 200 within --timeout, the chat cgroup's oom_kill counter does
        not move, and /health is still ok afterwards.
  The queues llama.cpp forms while the pool is full are measured, not failed: the long lane is
  expected to run first or wait, and the short lanes are expected to serialize in pairs.
  FAIL: any lane errors, the unit is OOM-killed, or the endpoint dies.

Exits 0 on pass and on a documented skip (no endpoint, model not downloaded).
"""

from __future__ import annotations

import argparse
import json
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import common  # noqa: E402


def sample_metrics(
    base_url: str, stop: threading.Event, samples: list[dict[str, float]]
) -> None:
    while not stop.is_set():
        values = common.metrics(base_url)
        if values:
            samples.append(values)
        stop.wait(1.0)


def run(args: argparse.Namespace) -> dict:
    common.require_endpoint(args.chat_url, args.models_dir, args.manifest)

    prompts = {}
    for name, target in common.LANES:
        text, counted = common.prompt_for_tokens(
            args.chat_url, target, f"lane-{name}", timeout=args.timeout
        )
        prompts[name] = {"text": text, "target": target, "tokens": counted}

    oom_before = common.oom_kills(args.cgroup)
    samples: list[dict[str, float]] = []
    stop = threading.Event()
    monitor = threading.Thread(target=sample_metrics, args=(args.chat_url, stop, samples), daemon=True)
    monitor.start()

    results: dict[str, dict] = {}
    lock = threading.Lock()
    start_gate = threading.Barrier(len(common.LANES))

    def lane(name: str) -> None:
        prompt = prompts[name]
        start_gate.wait()
        status, body, seconds = common.chat_completion(
            args.chat_url, prompt["text"], max_tokens=8, timeout=args.timeout
        )
        with lock:
            results[name] = {
                "target_tokens": prompt["target"],
                "counted_tokens": prompt["tokens"],
                "status": status,
                "seconds": round(seconds, 1),
                "answer": common.completion_text(body)[:120],
                "error": body if status != 200 else None,
            }

    threads = [threading.Thread(target=lane, args=(name,)) for name, _ in common.LANES]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(args.timeout + 60)

    stop.set()
    monitor.join(timeout=5)

    oom_after = common.oom_kills(args.cgroup)
    healthy_after = common.health(args.chat_url)
    peak_kv = max((s.get("llamacpp:kv_cache_usage_ratio", 0.0) for s in samples), default=None)
    peak_processing = max((s.get("llamacpp:requests_processing", 0.0) for s in samples), default=None)

    statuses = {name: results.get(name, {}).get("status", 0) for name, _ in common.LANES}
    oom_delta = None if oom_before is None or oom_after is None else oom_after - oom_before
    passed = (
        all(status == 200 for status in statuses.values())
        and oom_delta in (None, 0)
        and healthy_after
    )

    for name, _ in common.LANES:
        entry = results.get(name, {})
        print(
            f"{name:8s} target={entry.get('target_tokens', 0):6d} "
            f"counted={entry.get('counted_tokens') or '?':>7} "
            f"status={entry.get('status', 0)} seconds={entry.get('seconds', 0):7.1f}"
        )

    return {
        "check": "lane-fit",
        "pass": passed,
        "lanes": results,
        "statuses": statuses,
        "health_after": healthy_after,
        "oom_kill_before": oom_before,
        "oom_kill_after": oom_after,
        "peak_kv_cache_usage_ratio": peak_kv,
        "peak_requests_processing": peak_processing,
        "pool_tokens": 163840,
        "note": "229376 nominal tokens cannot be resident at once; queued lanes are expected",
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--chat-url", default=common.DEFAULT_CHAT_URL)
    parser.add_argument("--models-dir", type=Path, default=common.DEFAULT_MODELS_DIR)
    parser.add_argument("--manifest", type=Path, default=common.MANIFEST)
    parser.add_argument("--cgroup", type=Path, default=common.DEFAULT_CGROUP)
    parser.add_argument("--timeout", type=float, default=1800.0)
    parser.add_argument("--json-out", type=Path)
    args = parser.parse_args(argv)

    try:
        result = run(args)
    except common.Skip as exc:
        print(f"SKIP: {exc}")
        return 0
    common.emit(result, args.json_out)
    print("PASS" if result["pass"] else "FAIL")
    return 0 if result["pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
