#!/usr/bin/env python3
"""Long-context recall at 128k: a needle in the middle of the pool, one greedy answer.

PASS: the model's answer contains the needle phrase (all of its words, in order, normalised).
A miss at 128k fails the check; a skip (no endpoint or model) exits 0.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import common  # noqa: E402

NEEDLE = "the archive passphrase is amber river seven copper lantern moss"


def normalise(text: str) -> list[str]:
    return re.findall(r"[a-z0-9]+", text.lower())


def contains_needle(answer: str, needle: str) -> bool:
    wanted = normalise(needle)
    got = normalise(answer)
    if not wanted:
        return False
    for start in range(len(got) - len(wanted) + 1):
        if got[start : start + len(wanted)] == wanted:
            return True
    return False


def build_prompt(base_url: str, tokens: int, depth: float, timeout: float) -> tuple[str, int | None]:
    text, counted = common.prompt_for_tokens(base_url, tokens, "recall", timeout=timeout)
    # Insert the needle at the requested depth in characters; the tokenizer is roughly linear.
    cut = int(len(text) * depth)
    body = text[:cut] + "\n\n" + NEEDLE + "\n\n" + text[cut:]
    return (
        body
        + "\n\nQuestion: what is the archive passphrase? Reply with the phrase only, no explanation.\nAnswer:",
        counted,
    )


def run(args: argparse.Namespace) -> dict:
    common.require_endpoint(args.chat_url, args.models_dir, args.manifest)
    prompt, counted = build_prompt(args.chat_url, args.tokens, args.depth, args.timeout)
    status, body, seconds = common.chat_completion(
        args.chat_url, prompt, max_tokens=32, timeout=args.timeout, temperature=0.0
    )
    answer = common.completion_text(body)
    passed = status == 200 and contains_needle(answer, NEEDLE)
    timings = body.get("timings", {}) if isinstance(body, dict) else {}
    return {
        "check": "long-context-recall",
        "pass": passed,
        "tokens": args.tokens,
        "counted_tokens": counted,
        "depth": args.depth,
        "status": status,
        "seconds": round(seconds, 1),
        "answer": answer[:300],
        "prefill_tokens_per_second": timings.get("prompt_per_second"),
        "generation_tokens_per_second": timings.get("predicted_per_second"),
        "needle": NEEDLE,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--chat-url", default=common.DEFAULT_CHAT_URL)
    parser.add_argument("--models-dir", type=Path, default=common.DEFAULT_MODELS_DIR)
    parser.add_argument("--manifest", type=Path, default=common.MANIFEST)
    parser.add_argument("--tokens", type=int, default=131072)
    parser.add_argument("--depth", type=float, default=0.5)
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
