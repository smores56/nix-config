"""Command-line entry point for the photo-triage scaffold."""

from __future__ import annotations

import argparse
import os
import socket
import sys
from pathlib import Path

from . import __version__


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="photo-triage", description="Local photo triage for Immich"
    )
    parser.add_argument("--version", action="version", version=__version__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("doctor", help="check the data root and relay sockets")
    run = commands.add_parser("run", help="score the library (service only)")
    run.add_argument("--dev-fixtures", action="store_true", help=argparse.SUPPRESS)
    return parser


def doctor() -> int:
    data_dir = Path(os.environ.get("PHOTO_TRIAGE_DATA_DIR", "/var/lib/photo-triage"))
    sockets = {
        "immich": Path(
            os.environ.get("PHOTO_TRIAGE_IMMICH_SOCKET", "/run/photo-triage/immich.sock")
        ),
        "llm": Path(os.environ.get("PHOTO_TRIAGE_LLM_SOCKET", "/run/photo-triage/llm.sock")),
    }
    problems = []
    if not data_dir.is_dir():
        problems.append(f"missing data dir: {data_dir}")
    elif not os.access(data_dir, os.W_OK):
        problems.append(f"data dir is not writable: {data_dir}")
    for name, path in sockets.items():
        if not path.exists():
            problems.append(f"missing {name} relay socket: {path}")
        elif not path.is_socket():
            problems.append(f"not a socket: {path}")
        else:
            try:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as probe:
                    probe.settimeout(1)
                    probe.connect(str(path))
            except OSError as error:
                problems.append(f"cannot connect to {name} relay {path}: {error}")
    for problem in problems:
        print(f"fail: {problem}", file=sys.stderr)
    if problems:
        return 1
    print(f"ok data={data_dir} immich={sockets['immich']} llm={sockets['llm']}")
    return 0


def run(dev_fixtures: bool) -> int:
    if not dev_fixtures and os.environ.get("PHOTO_TRIAGE_UNIT") != "1":
        print(
            "photo-triage: run through the service, or pass --dev-fixtures",
            file=sys.stderr,
        )
        return 2
    print("photo-triage: scoring is not implemented in this scaffold", file=sys.stderr)
    return 0


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.command == "doctor":
        return doctor()
    if args.command == "run":
        return run(args.dev_fixtures)
    return 2
