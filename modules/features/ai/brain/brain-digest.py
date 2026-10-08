#!/usr/bin/env python3
"""Reduce one day of Claude Code transcripts to a compact per-session digest.

Raw transcripts run to tens of MB a day (tool output, file dumps), far past
what a summarizing agent can read; this keeps only what a work log needs.
Output feeds an agent that writes durable notes, so free text is sanitized,
stripped of harness envelopes, and redacted of token-shaped secrets.
"""
import argparse
import json
import os
import re
import sys
from dataclasses import dataclass
from datetime import date, datetime, time, timezone
from pathlib import Path, PurePath

KEPT_TYPES = frozenset({"user", "assistant", "ai-title"})
WRITE_TOOLS = frozenset({"Edit", "MultiEdit", "Write", "NotebookEdit"})
TICKET_RE = re.compile(r"\b([A-Z][A-Z0-9]{1,9})-(\d+)\b")
# Uppercase-dash-number tokens that are standards or models, not tickets.
TICKET_LOOKALIKES = frozenset({"UTF", "SHA", "ISO", "RFC", "GPT", "PEP"})
PR_RE = re.compile(r"https://github\.com/[\w.-]+/[\w.-]+/pull/\d+")
# Only these gh subcommands mean Sam acted on the PR; list/view output is reading.
PR_WRITE_RE = re.compile(r"\bgh\s+pr\s+(create|merge|edit|ready|comment|review|close|reopen)\b")
# Harness-injected envelopes: none of them is something Sam said.
ENVELOPE_TAGS = (
    "system-reminder",
    "task-notification",
    "bash-stdout",
    "bash-stderr",
    "local-command-stdout",
    "local-command-caveat",
)
ENVELOPE_RE = re.compile(
    r"<({0})\b[^>]*>.*?</\1>|</?({0})\b[^>]*>".format("|".join(ENVELOPE_TAGS)), re.DOTALL
)
COMMAND_RE = re.compile(r"<command-name>\s*(.*?)\s*</command-name>", re.DOTALL)
COMMAND_ARGS_RE = re.compile(r"<command-args>\s*(.*?)\s*</command-args>", re.DOTALL)
BASH_INPUT_RE = re.compile(r"<bash-input>\s*(.*?)\s*</bash-input>", re.DOTALL)
# C0/C1 controls (keeping \t \n \r), bidi overrides/isolates/marks, and the
# Unicode line separators that break JSON-lines framing under splitlines().
CTRL_RE = re.compile(
    r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f‎‏  ‪-‮⁦-⁩]"
)
SECRET_RE = re.compile(
    r"gh[pousr]_[A-Za-z0-9]{20,}"
    r"|github_pat_[A-Za-z0-9_]{20,}"
    r"|xox[abprs]-[A-Za-z0-9-]{10,}"
    r"|AKIA[0-9A-Z]{16}"
    r"|sk-[A-Za-z0-9_-]{20,}"
    r"|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"
    r"|-----BEGIN [A-Z ]+-----"
)
CREDENTIAL_DIRS = frozenset({".ssh", ".aws", ".gnupg", ".kube"})


@dataclass(frozen=True)
class Options:
    max_prompts: int = 10
    max_prompt_chars: int = 300
    max_reply_chars: int = 600
    ticket_prefixes: tuple[str, ...] = ()


def parse_records(lines):
    def parse(line):
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            return None
        return record if isinstance(record, dict) else None

    return [r for r in map(parse, lines) if r is not None]


def parse_ts(value):
    try:
        ts = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (AttributeError, TypeError, ValueError):
        return None
    # Claude writes UTC; a stray naive stamp is read as UTC so sorting stays total.
    return ts if ts.tzinfo else ts.replace(tzinfo=timezone.utc)


def localize(ts, tz):
    # tz=None resolves the system zone per timestamp, so DST shifts land on the right day.
    return ts.astimezone(tz) if tz else ts.astimezone()


def clean(text):
    return SECRET_RE.sub("[REDACTED]", CTRL_RE.sub("", ENVELOPE_RE.sub("", text))).strip()


def truncate(text, limit):
    return text if len(text) <= limit else text[:limit] + "…"


def blocks(record):
    message = record.get("message")
    content = message.get("content") if isinstance(message, dict) else None
    if isinstance(content, str):
        return [{"type": "text", "text": content}]
    return [b for b in content if isinstance(b, dict)] if isinstance(content, list) else []


def as_text(value):
    return value if isinstance(value, str) else ""


def block_text(block):
    if block.get("type") == "text":
        return as_text(block.get("text"))
    if block.get("type") == "tool_result":
        content = block.get("content")
        if isinstance(content, list):
            return "\n".join(as_text(c.get("text")) for c in content if isinstance(c, dict))
        return as_text(content)
    return ""


def tool_input(block):
    value = block.get("input")
    return value if isinstance(value, dict) else {}


def raw_prompt(record):
    if (
        record.get("type") != "user"
        or record.get("isMeta")
        or record.get("isCompactSummary")
        or record.get("isVisibleInTranscriptOnly")
    ):
        return None
    texts = [block_text(b) for b in blocks(record) if b.get("type") == "text"]
    return "\n".join(texts) if texts else None


def prompt_text(record):
    raw = raw_prompt(record)
    if raw is None:
        return None
    if command := COMMAND_RE.search(raw):
        args = COMMAND_ARGS_RE.search(raw)
        return clean(" ".join(filter(None, [command.group(1), args and args.group(1)])))
    if shell := BASH_INPUT_RE.search(raw):
        return clean("!" + shell.group(1))
    return clean(raw) or None


def reply_text(record):
    if record.get("type") != "assistant":
        return None
    texts = [as_text(b.get("text")) for b in blocks(record) if b.get("type") == "text"]
    return clean("\n".join(texts)) or None


def tickets_in(text, prefixes):
    keys = (f"{p}-{n}" for p, n in TICKET_RE.findall(text) if p not in TICKET_LOOKALIKES)
    return [k for k in keys if not prefixes or k.split("-")[0] in prefixes]


def pr_write_texts(records):
    """Commands and outputs of `gh pr <write>` calls: the PRs Sam acted on."""
    tool_uses = [
        b for r in records if r.get("type") == "assistant" for b in blocks(r) if b.get("type") == "tool_use"
    ]
    commands = {
        b.get("id"): as_text(tool_input(b).get("command"))
        for b in tool_uses
        if isinstance(b.get("id"), str)
        and b.get("name") == "Bash"
        and PR_WRITE_RE.search(as_text(tool_input(b).get("command")))
    }
    outputs = [
        block_text(b)
        for r in records
        if r.get("type") == "user"
        for b in blocks(r)
        if b.get("type") == "tool_result" and b.get("tool_use_id") in commands
    ]
    return list(commands.values()) + outputs


def is_credential_path(path):
    parts = PurePath(path).parts
    return bool(CREDENTIAL_DIRS.intersection(parts)) or parts[-1].startswith(".env")


def unique(items):
    return list(dict.fromkeys(items))


def summarize_session(session_id, records, day, tz, opts, sidechain=False):
    titles = [clean(as_text(r.get("aiTitle"))) for r in records if r.get("type") == "ai-title"]
    stamped = [
        (ts, r)
        for r in records
        # A subagent transcript is all sidechain; in a main session those records are noise.
        if r.get("type") in ("user", "assistant") and (sidechain or not r.get("isSidechain"))
        if (ts := parse_ts(r.get("timestamp"))) and localize(ts, tz).date() == day
    ]
    if not stamped:
        return None
    stamped.sort(key=lambda pair: pair[0])
    active = [r for _, r in stamped]

    prompts = [p for p in map(prompt_text, active) if p]
    replies = [t for t in map(reply_text, active) if t]
    conversation = prompts + replies
    edited = [
        as_text(tool_input(b).get("file_path") or tool_input(b).get("notebook_path"))
        for r in active
        if r.get("type") == "assistant"
        for b in blocks(r)
        if b.get("type") == "tool_use" and b.get("name") in WRITE_TOOLS
    ]

    return {
        "session_id": session_id,
        "title": next((t for t in reversed(titles) if t), None),
        "cwds": unique(clean(as_text(r.get("cwd"))) for r in active if r.get("cwd")),
        "branches": unique(clean(as_text(r.get("gitBranch"))) for r in active if r.get("gitBranch")),
        "start": localize(stamped[0][0], tz).isoformat(),
        "end": localize(stamped[-1][0], tz).isoformat(),
        "prompt_count": len(prompts),
        "prompts": [truncate(p, opts.max_prompt_chars) for p in prompts[: opts.max_prompts]],
        "last_reply": truncate(replies[-1], opts.max_reply_chars) if replies else None,
        "tickets": unique(k for t in conversation for k in tickets_in(t, opts.ticket_prefixes)),
        "prs": unique(u for t in conversation + pr_write_texts(active) for u in PR_RE.findall(t)),
        "edited_files": unique(clean(f) for f in edited if f and not is_credential_path(f)),
    }


@dataclass(frozen=True)
class Transcript:
    path: Path
    kind: str  # "session" or "subagent"
    parent_session: str | None = None


def transcripts(root):
    # Main sessions are <project>/<id>.jsonl; their subagents live in <project>/<id>/subagents/.
    sessions = [Transcript(p, "session") for p in root.glob("*/*.jsonl") if p.is_file()]
    subagents = [
        Transcript(p, "subagent", p.parent.parent.name)
        for p in root.glob("*/*/subagents/*.jsonl")
        if p.is_file()
    ]
    return sorted(sessions + subagents, key=lambda t: t.path)


def subagent_meta(path):
    try:
        meta = json.loads(path.with_suffix(".meta.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return meta if isinstance(meta, dict) else {}


def day_start(day, tz):
    return datetime.combine(day, time.min, tzinfo=tz) if tz else datetime.combine(day, time.min).astimezone()


def digest(root, day, tz, opts):
    # A file untouched since before the day began cannot hold records from it.
    cutoff = day_start(day, tz).timestamp()

    def load(transcript):
        path = transcript.path
        try:
            if path.stat().st_mtime < cutoff:
                return None
            with path.open(encoding="utf-8", errors="replace") as f:
                records = [r for r in parse_records(f) if r.get("type") in KEPT_TYPES]
            is_subagent = transcript.kind == "subagent"
            summary = summarize_session(path.stem, records, day, tz, opts, sidechain=is_subagent)
            if summary is None:
                return None
            meta = subagent_meta(path) if is_subagent else {}
            description = clean(as_text(meta.get("description")))
            return {
                **summary,
                "title": description or summary["title"],
                "kind": transcript.kind,
                "parent_session": transcript.parent_session,
                "agent_type": clean(as_text(meta.get("agentType"))) or None,
            }
        except Exception as err:  # one bad transcript must not blank the whole day
            print(f"brain-digest: skipping {path}: {err}", file=sys.stderr)
            return None

    sessions = [s for s in map(load, transcripts(root)) if s]
    return sorted(sessions, key=lambda s: datetime.fromisoformat(s["start"]))


def default_root():
    config_dir = os.environ.get("CLAUDE_CONFIG_DIR")
    return (Path(config_dir) if config_dir else Path.home() / ".claude") / "projects"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=default_root())
    parser.add_argument("--date", type=date.fromisoformat, help="local date (default: today)")
    parser.add_argument("--utc", action="store_true", help="bucket days in UTC instead of local time")
    parser.add_argument(
        "--ticket-prefix", action="append", default=[], help="only keep tickets with this key prefix"
    )
    args = parser.parse_args(argv)

    tz = timezone.utc if args.utc else None
    day = args.date or datetime.now(tz).astimezone(tz).date()
    opts = Options(ticket_prefixes=tuple(args.ticket_prefix))
    for session in digest(args.root, day, tz, opts):
        print(json.dumps(session, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
