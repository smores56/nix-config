#!/usr/bin/env python3
import argparse
import json
import os
import signal
import sys
from collections import namedtuple
from datetime import datetime, timezone
from pathlib import Path


Session = namedtuple("Session", "id cwd title updated_at messages")
DEFAULT_TITLE = "New session"
MAX_SEARCH_TEXT = 600


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


def load_session(path):
    header = None
    title = DEFAULT_TITLE
    updated_at = 0
    messages = []

    try:
        lines = path.read_text().splitlines()
    except OSError as error:
        raise ValueError(f"cannot read {path}: {error}") from error

    for line in lines:
        if not line:
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(record, dict):
            continue
        if record.get("t") == "header":
            header = record
        elif record.get("t") == "meta":
            title = record.get("title") if isinstance(record.get("title"), str) else title
            updated_at = record.get("updated_at") if isinstance(record.get("updated_at"), int) else updated_at
        elif record.get("t") == "msg":
            message = record.get("d")
            if isinstance(message, dict) and message.get("role") in {"user", "assistant"}:
                messages.extend(text_blocks(message))

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


def format_timestamp(epoch):
    return datetime.fromtimestamp(epoch, tz=timezone.utc).strftime("%Y-%m-%d %H:%M")


def format_entry(session):
    title = " ".join(session.title.split())
    search_text = " ".join(" ".join(session.messages).split())[:MAX_SEARCH_TEXT]
    return f"{session.id} {title} · {session.cwd} · {format_timestamp(session.updated_at)} · {search_text}"


def find_session(session_id):
    for path in session_files():
        try:
            session = load_session(path)
        except ValueError:
            continue
        if session.id == session_id:
            return session
    raise ValueError(f"session not found: {session_id}")


def list_sessions():
    sessions = []
    for path in session_files():
        try:
            sessions.append(load_session(path))
        except ValueError as error:
            print(error, file=sys.stderr)
    return sorted(sessions, key=lambda session: session.updated_at, reverse=True)


def main():
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    parser = argparse.ArgumentParser(description="Search Maki sessions for Television")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("list")
    for command in ("cwd", "show"):
        subparser = commands.add_parser(command)
        subparser.add_argument("session_id")
    args = parser.parse_args()

    if args.command == "list":
        for session in list_sessions():
            print(format_entry(session))
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
