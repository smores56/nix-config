#!/usr/bin/env python3
"""Run the whole kanbei inference eval: lane fit, 128k recall, q8_0-vs-f16 sampling.

Every step skips with exit 0 when its endpoint or model is missing, so this is the single
command to run inside the guest (`kanbei-inference-eval`) or from the host over a relay.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import common  # noqa: E402
import lane_fit  # noqa: E402
import long_context_recall  # noqa: E402
import quality_sample  # noqa: E402


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--chat-url", default=common.DEFAULT_CHAT_URL)
    parser.add_argument("--fp16-url", default=common.DEFAULT_FP16_URL)
    parser.add_argument("--models-dir", type=Path, default=common.DEFAULT_MODELS_DIR)
    parser.add_argument("--manifest", type=Path, default=common.MANIFEST)
    parser.add_argument("--tokens", type=int, default=131072)
    parser.add_argument("--depth", type=float, default=0.5)
    parser.add_argument("--timeout", type=float, default=1800.0)
    parser.add_argument("--json-dir", type=Path)
    args = parser.parse_args(argv)

    shared = [
        "--chat-url",
        args.chat_url,
        "--models-dir",
        str(args.models_dir),
        "--manifest",
        str(args.manifest),
        "--timeout",
        str(args.timeout),
    ]
    out = args.json_dir
    if out is not None:
        out.mkdir(parents=True, exist_ok=True)

    steps = [
        (
            "lane-fit",
            lane_fit.main,
            shared + ([] if out is None else ["--json-out", str(out / "lane-fit.json")]),
        ),
        (
            "long-context-recall",
            long_context_recall.main,
            shared
            + ["--tokens", str(args.tokens), "--depth", str(args.depth)]
            + ([] if out is None else ["--json-out", str(out / "long-context-recall.json")]),
        ),
        (
            "quality-sample",
            quality_sample.main,
            shared
            + ["--fp16-url", args.fp16_url]
            + ([] if out is None else ["--json-out", str(out / "quality-sample.json")]),
        ),
    ]

    codes: dict[str, int] = {}
    for name, step, step_argv in steps:
        print(f"\n== {name}")
        codes[name] = step(step_argv)
    print("\n== summary")
    for name, code in codes.items():
        print(f"{name:22s} {'PASS' if code == 0 else 'FAIL'}")
    return 1 if any(code != 0 for code in codes.values()) else 0


if __name__ == "__main__":
    sys.exit(main())
