#!/usr/bin/env python3
"""Monthly Cloudflare Workers AI spend for maki.

maki persists per-session token counts to its session JSONL logs but never the
dollar cost, and has no cross-session rollup. This scans those logs, applies the
same per-1M-token pricing as the maki cloudflare provider config, and prints a
monthly summary. Estimate only — Cloudflare's dashboard is the billing source of
truth.

Cloudflare does automatic prefix caching and reports cached input separately;
maki records it as `cache_read_input_tokens` (and cache writes as
`cache_creation_input_tokens`). Cached reads are billed at a discount, so they
are priced separately here — ignoring them would under-count real spend.

Managed by home-manager (modules/features/ai/maki). Manual edits are clobbered.
"""

import glob
import json
import os
import sys
from collections import defaultdict
from datetime import datetime, timezone

# USD per 1,000,000 tokens: (input, output, cache_read). Keep in sync with
# cloudflareModels in modules/features/ai/providers.nix. Only GLM-5.2 publishes
# a discounted cached-input rate ($0.26/1M); gpt-oss models publish none, so
# their cached reads are priced at the input rate (conservative — never
# under-counts). cache_creation is priced as normal input.
PRICING = {
    "@cf/zai-org/glm-5.2": (1.40, 4.40, 0.26),
    "@cf/openai/gpt-oss-120b": (0.35, 0.75, 0.35),
    "@cf/openai/gpt-oss-20b": (0.20, 0.30, 0.20),
}


def session_dirs():
    override = os.environ.get("MAKI_SESSIONS_DIR")
    if override:
        return [override]
    home = os.path.expanduser("~")
    xdg_state = os.environ.get("XDG_STATE_HOME", os.path.join(home, ".local", "state"))
    xdg_data = os.environ.get("XDG_DATA_HOME", os.path.join(home, ".local", "share"))
    roots = [
        os.path.join(home, ".maki"),
        os.path.join(xdg_state, "maki"),
        os.path.join(xdg_data, "maki"),
        os.path.join(home, "Library", "Application Support", "maki"),
        os.path.join(home, "Library", "Application Support", "state", "maki"),
    ]
    return [os.path.join(r, "sessions") for r in roots]


def session_files():
    found = {}
    for d in session_dirs():
        if not os.path.isdir(d):
            continue
        for f in glob.glob(os.path.join(d, "*.jsonl")) + glob.glob(os.path.join(d, "*.json")):
            if os.path.basename(f) == "cwd_latest.json":
                continue
            found[os.path.realpath(f)] = True
    return list(found)


def price_for(model):
    if not model:
        return None
    for model_id, rates in PRICING.items():
        if model_id in model:
            return rates
    return None


def parse_session(path):
    model = None
    created_at = None
    usage = None
    updated_at = None
    try:
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(obj, dict):
                    continue
                if model is None and obj.get("model"):
                    model = obj["model"]
                if created_at is None and obj.get("created_at"):
                    created_at = obj["created_at"]
                tu = obj.get("token_usage")
                if not isinstance(tu, dict) and "input_tokens" in obj:
                    tu = obj
                if isinstance(tu, dict) and ("input_tokens" in tu or "output_tokens" in tu):
                    usage = tu
                    if obj.get("updated_at"):
                        updated_at = obj["updated_at"]
    except OSError:
        return None
    if usage is None:
        return None
    return {"model": model, "usage": usage, "ts": updated_at or created_at}


def month_of(ts):
    if ts is None:
        return "unknown"
    try:
        if isinstance(ts, (int, float)):
            return datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%Y-%m")
        dt = datetime.fromisoformat(str(ts).replace("Z", "+00:00"))
        return dt.strftime("%Y-%m")
    except (ValueError, OSError, OverflowError):
        return "unknown"


def cost_for(usage, rates):
    """(input, cache_creation) priced at the input rate; cache_read at the cached
    rate; output at the output rate. Returns USD."""
    in_rate, out_rate, cache_rate = rates
    inp = int(usage.get("input_tokens", 0) or 0)
    out = int(usage.get("output_tokens", 0) or 0)
    cache_read = int(usage.get("cache_read_input_tokens", 0) or 0)
    cache_creation = int(usage.get("cache_creation_input_tokens", 0) or 0)
    return (inp * in_rate + cache_creation * in_rate + cache_read * cache_rate + out * out_rate) / 1_000_000


def main():
    files = session_files()
    if not files:
        print("No maki session logs found. Looked in:", file=sys.stderr)
        for d in session_dirs():
            print(f"  {d}", file=sys.stderr)
        print("Set MAKI_SESSIONS_DIR to point at the sessions directory.", file=sys.stderr)
        return 1

    months = defaultdict(lambda: {"in": 0, "cached": 0, "out": 0, "cost": 0.0, "sessions": 0, "unpriced": 0})
    per_model = defaultdict(lambda: {"in": 0, "cached": 0, "out": 0, "cost": 0.0})

    for path in files:
        s = parse_session(path)
        if not s:
            continue
        u = s["usage"]
        inp = int(u.get("input_tokens", 0) or 0)
        out = int(u.get("output_tokens", 0) or 0)
        cached = int(u.get("cache_read_input_tokens", 0) or 0)
        m = months[month_of(s["ts"])]
        m["sessions"] += 1
        m["in"] += inp
        m["out"] += out
        m["cached"] += cached
        rates = price_for(s["model"])
        label = s["model"] or "unknown"
        per_model[label]["in"] += inp
        per_model[label]["out"] += out
        per_model[label]["cached"] += cached
        if rates:
            cost = cost_for(u, rates)
            m["cost"] += cost
            per_model[label]["cost"] += cost
        else:
            m["unpriced"] += 1

    print("Cloudflare Workers AI spend (estimated from maki session logs)\n")
    header = (
        f"{'Month':<9} {'Sessions':>8} {'Input tok':>14} {'Cached tok':>14} "
        f"{'Output tok':>14} {'Cost (USD)':>12}"
    )
    print(header)
    print("-" * len(header))
    total = {"in": 0, "cached": 0, "out": 0, "cost": 0.0, "sessions": 0, "unpriced": 0}
    for month in sorted(months):
        r = months[month]
        flag = f"  ({r['unpriced']} unpriced)" if r["unpriced"] else ""
        print(
            f"{month:<9} {r['sessions']:>8} {r['in']:>14,} {r['cached']:>14,} "
            f"{r['out']:>14,} {'$' + format(r['cost'], '.2f'):>12}{flag}"
        )
        for k in total:
            total[k] += r[k]
    print("-" * len(header))
    print(
        f"{'TOTAL':<9} {total['sessions']:>8} {total['in']:>14,} {total['cached']:>14,} "
        f"{total['out']:>14,} {'$' + format(total['cost'], '.2f'):>12}"
    )

    print("\nBy model:")
    for model in sorted(per_model, key=lambda k: per_model[k]["cost"], reverse=True):
        r = per_model[model]
        priced = "" if price_for(model) else "  (no pricing entry)"
        print(
            f"  {model:<32} in {r['in']:>12,}  cached {r['cached']:>12,}  "
            f"out {r['out']:>12,}  ${r['cost']:.2f}{priced}"
        )

    if total["unpriced"]:
        print(f"\n{total['unpriced']} session(s) used a model with no pricing entry; their cost is $0.00 above.")
    print("\nCached reads are billed at the model's discounted cached rate (GLM-5.2: $0.26/1M).")
    print("Estimate only — see the Cloudflare dashboard for authoritative billing.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
