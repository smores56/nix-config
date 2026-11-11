#!/usr/bin/env python3
"""q8_0-VM vs f16 quality sampling for the chat lane.

The serving lane uses q8_0 K and V. This check sends the same greedy prompts to that lane and to
a second chat server started with `-ctk f16 -ctv f16` (documented in docs/kanbei-inference.md),
then scores how much the quantised KV changes the answers.

PASS: exact-match rate >= --min-exact (default 0.9) and mean SequenceMatcher similarity
      >= --min-similarity (default 0.98) over the samples.
SKIP: the f16 reference server is absent, the q8_0 lane is absent, or a model file is missing.
"""

from __future__ import annotations

import argparse
import difflib
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import common  # noqa: E402

PROMPTS = (
    "Reply with one sentence: what does a restic repository need before its first snapshot?",
    "Name three reasons to keep a LUKS recovery key off the machine, in one sentence.",
    "In one sentence, explain why a NIC-less VM still needs a loopback listener.",
    "Reply with one sentence: what is the risk of a shared unified KV cache?",
    "Summarise in one sentence why a hybrid attention model stores KV on only some layers.",
    "Reply with one sentence: when should a systemd unit set RequiresMountsFor?",
    "Name the first thing to check when a llama-server starts but no slot ever becomes ready.",
    "In one sentence, describe what q8_0 does to the K and V caches.",
)


def answer(base_url: str, prompt: str, args: argparse.Namespace) -> tuple[int, str]:
    status, body, _ = common.chat_completion(
        base_url, prompt, max_tokens=args.max_tokens, timeout=args.timeout, temperature=0.0
    )
    return status, common.completion_text(body)


def similarity(left: str, right: str) -> float:
    return difflib.SequenceMatcher(None, left, right).ratio()


def run(args: argparse.Namespace) -> dict:
    common.require_endpoint(args.chat_url, args.models_dir, args.manifest)
    if not common.health(args.fp16_url):
        raise common.Skip(f"no f16-KV reference server at {args.fp16_url}")

    samples = []
    for prompt in PROMPTS[: args.samples]:
        q8_status, q8_text = answer(args.chat_url, prompt, args)
        f16_status, f16_text = answer(args.fp16_url, prompt, args)
        samples.append(
            {
                "prompt": prompt,
                "q8_status": q8_status,
                "f16_status": f16_status,
                "exact": q8_text.strip() == f16_text.strip(),
                "similarity": round(similarity(q8_text, f16_text), 4),
                "q8": q8_text[:200],
                "f16": f16_text[:200],
            }
        )

    usable = [s for s in samples if s["q8_status"] == 200 and s["f16_status"] == 200]
    exact_rate = (
        sum(1 for s in usable if s["exact"]) / len(usable) if usable else 0.0
    )
    mean_similarity = (
        sum(s["similarity"] for s in usable) / len(usable) if usable else 0.0
    )
    passed = (
        len(usable) == len(samples)
        and exact_rate >= args.min_exact
        and mean_similarity >= args.min_similarity
    )
    return {
        "check": "quality-sample",
        "pass": passed,
        "samples": samples,
        "exact_match_rate": round(exact_rate, 4),
        "mean_similarity": round(mean_similarity, 4),
        "min_exact": args.min_exact,
        "min_similarity": args.min_similarity,
        "q8_url": args.chat_url,
        "f16_url": args.fp16_url,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--chat-url", default=common.DEFAULT_CHAT_URL)
    parser.add_argument("--fp16-url", default=common.DEFAULT_FP16_URL)
    parser.add_argument("--models-dir", type=Path, default=common.DEFAULT_MODELS_DIR)
    parser.add_argument("--manifest", type=Path, default=common.MANIFEST)
    parser.add_argument("--samples", type=int, default=len(PROMPTS))
    parser.add_argument("--max-tokens", type=int, default=64)
    parser.add_argument("--min-exact", type=float, default=0.9)
    parser.add_argument("--min-similarity", type=float, default=0.98)
    parser.add_argument("--timeout", type=float, default=600.0)
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
