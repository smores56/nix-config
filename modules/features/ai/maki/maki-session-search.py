#!/usr/bin/env python3
import argparse
import json
import os
import re
import signal
import sys
import tempfile
from collections import namedtuple
from datetime import datetime, timezone
from pathlib import Path

Session = namedtuple("Session", "id cwd title updated_at messages")
DEFAULT_TITLE = "New session"
MAX_SEARCH_TEXT = 600
MAX_SEARCH_TEXT_JSON = 20000
CACHE_VERSION = 1

# Strip terminal control bytes (C0/C1) and bidi/RTL overrides that would
# execute or visually hijack a TUI renderer (Television, the maki picker).
_CTRL_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f\u202a-\u202e\u200e\u200f]")


def sanitize(text):
    return _CTRL_RE.sub("", text)


def session_dirs():
    override = os.environ.get("MAKI_SESSIONS_DIR")
    if override:
        return [Path(override)]

    home = Path.home()
    state = Path(os.environ.get("XDG_STATE_HOME", home / ".local" / "state"))
    data = Path(os.environ.get("XDG_DATA_HOME", home / ".local" / "share"))
    return [
        home / ".maki" / "sessions",
        state / "maki" / "sessions",
        data / "maki" / "sessions",
        home / "Library" / "Application Support" / "maki" / "sessions",
        home / "Library" / "Application Support" / "state" / "maki" / "sessions",
    ]


def session_files():
    return [
        path
        for directory in session_dirs()
        if directory.is_dir()
        for path in directory.glob("*.jsonl")
        if path.name != "cwd_latest.json"
    ]


def text_blocks(message):
    content = message.get("content", [])
    if not isinstance(content, list):
        return []
    return [
        block["text"].strip()
        for block in content
        if isinstance(block, dict) and block.get("type") == "text" and isinstance(block.get("text"), str)
        if block["text"].strip()
    ]


def _apply_meta(record, title, updated_at):
    if isinstance(record.get("title"), str):
        title = record["title"]
    if isinstance(record.get("updated_at"), int):
        updated_at = record["updated_at"]
    return title, updated_at


def _msg_texts(record):
    message = record.get("d")
    if isinstance(message, dict) and message.get("role") in {"user", "assistant"}:
        return text_blocks(message)
    return []


def _build_session(path, header, title, updated_at, messages):
    if not isinstance(header, dict):
        raise ValueError(f"{path}: missing session header")
    session_id = header.get("id")
    cwd = header.get("cwd")
    if not isinstance(session_id, str) or not session_id or not isinstance(cwd, str) or not cwd:
        raise ValueError(f"{path}: invalid session header")
    created_at = header.get("created_at")
    if updated_at == 0 and isinstance(created_at, int):
        updated_at = created_at
    return Session(session_id, cwd, title, updated_at, messages)


def load_session(path):
    header = None
    title = DEFAULT_TITLE
    updated_at = 0
    messages = []
    try:
        for line in path.read_text().splitlines():
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(record, dict):
                continue
            t = record.get("t")
            if t == "header":
                header = record
            elif t == "meta":
                title, updated_at = _apply_meta(record, title, updated_at)
            elif t == "msg":
                messages.extend(_msg_texts(record))
    except OSError as error:
        raise ValueError(f"cannot read {path}: {error}") from error
    return _build_session(path, header, title, updated_at, messages)


# Per-file cache for fast listing. Stores one entry per session file, keyed by
# the file's absolute path. Each entry records mtime + size so only changed
# files are re-parsed on subsequent runs: one cold build parses every file,
# then steady state re-parses only the sessions that changed (typically just
# the active one). Backs both `list` (Television) and `list --json` (picker);
# `show`/`cwd` always read the full file.

def _cache_path():
    home = Path.home()
    state = Path(os.environ.get("XDG_STATE_HOME", home / ".local" / "state"))
    return state / "maki" / "session-search-index.json"


def _load_cache():
    try:
        data = json.loads(_cache_path().read_text())
    except (OSError, json.JSONDecodeError):
        return {}
    if not isinstance(data, dict) or data.get("version") != CACHE_VERSION:
        return {}
    entries = data.get("entries")
    return entries if isinstance(entries, dict) else {}


def _save_cache(entries):
    path = _cache_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    blob = json.dumps({"version": CACHE_VERSION, "entries": entries})
    fd, tmp = tempfile.mkstemp(dir=path.parent, suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(blob)
        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def _compute_entry(path, stat):
    session = load_session(path)
    search_text = sanitize(" ".join(" ".join(session.messages).split())[:MAX_SEARCH_TEXT_JSON])
    return {
        "mtime": stat.st_mtime,
        "size": stat.st_size,
        "id": session.id,
        "cwd": sanitize(session.cwd),
        "title": sanitize(" ".join(session.title.split())),
        "updated_at": session.updated_at,
        "search_text": search_text,
    }


def list_sessions():
    cache = _load_cache()
    live_paths = {str(p) for p in session_files()}
    entries = {}
    results = []
    for path_str in sorted(live_paths):
        path = Path(path_str)
        try:
            stat = path.stat()
        except OSError:
            continue
        cached = cache.get(path_str)
        if (
            isinstance(cached, dict)
            and cached.get("mtime") == stat.st_mtime
            and cached.get("size") == stat.st_size
            and "id" in cached
            and "search_text" in cached
        ):
            entry = cached
        else:
            try:
                entry = _compute_entry(path, stat)
            except (ValueError, OSError) as error:
                print(f"cannot read {path}: {error}", file=sys.stderr)
                continue
        entries[path_str] = entry
        results.append(entry)
    _save_cache(entries)
    results.sort(key=lambda e: e["updated_at"], reverse=True)
    return results


def format_timestamp(epoch):
    return datetime.fromtimestamp(epoch, tz=timezone.utc).strftime("%Y-%m-%d %H:%M")


def format_entry(entry):
    search_text = entry["search_text"][:MAX_SEARCH_TEXT]
    return f'{entry["id"]} {entry["title"]} · {entry["cwd"]} · {format_timestamp(entry["updated_at"])} · {search_text}'


def json_entry(entry):
    return json.dumps(
        {
            "id": entry["id"],
            "title": entry["title"],
            "cwd": entry["cwd"],
            "updated_at": entry["updated_at"],
            "search_text": entry["search_text"],
        },
        ensure_ascii=False,
    )


def find_session(session_id):
    for path in session_files():
        try:
            session = load_session(path)
        except ValueError:
            continue
        if session.id == session_id:
            return session
    raise ValueError(f"session not found: {session_id}")


def main():
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    parser = argparse.ArgumentParser(description="Search Maki sessions for Television")
    commands = parser.add_subparsers(dest="command", required=True)
    list_parser = commands.add_parser("list")
    list_parser.add_argument("--json", action="store_true", help="Emit JSON lines for machine consumers")
    for command in ("cwd", "show"):
        subparser = commands.add_parser(command)
        subparser.add_argument("session_id")
    args = parser.parse_args()

    if args.command == "list":
        if args.json:
            for entry in list_sessions():
                print(json_entry(entry), flush=True)
        else:
            for entry in list_sessions():
                print(format_entry(entry))
        return

    try:
        session = find_session(args.session_id)
    except ValueError as error:
        parser.error(str(error))

    if args.command == "cwd":
        print(session.cwd)
    else:
        print(f"{session.title}\n{session.cwd}\n")
        print("\n\n".join(session.messages))


if __name__ == "__main__":
    main()
