"""Command-line entry point for photo-triage."""

from __future__ import annotations

import argparse
import json
import os
import socket
import sys
from pathlib import Path

from . import __version__
from .albums import AlbumError, album_status, load_export, preflight, sync_export
from .db import Database
from .decisions import POLICY, decide_scan
from .duplicates import PHASH_THRESHOLD, analyze_scan
from .immich import ImmichClient, ImmichError
from .model import LLMClient, LLMError, MODEL_ALIAS
from .scan import PAGE_SIZE, scan_library
from .score import ScorerError, score_library

DB_NAME = "triage.db"
DEFAULT_DATA_DIR = "/var/lib/photo-triage"
DEFAULT_IMMICH_SOCKET = "/run/photo-triage/immich.sock"
DEFAULT_IMMICH_ALBUM_SOCKET = "/run/photo-triage/immich-album.sock"
DEFAULT_LLM_SOCKET = "/run/photo-triage/llm.sock"


def data_dir() -> Path:
    return Path(os.environ.get("PHOTO_TRIAGE_DATA_DIR", DEFAULT_DATA_DIR))


def immich_socket() -> str:
    return os.environ.get("PHOTO_TRIAGE_IMMICH_SOCKET", DEFAULT_IMMICH_SOCKET)


def llm_socket() -> str:
    return os.environ.get("PHOTO_TRIAGE_LLM_SOCKET", DEFAULT_LLM_SOCKET)


def album_socket() -> str:
    return os.environ.get("PHOTO_TRIAGE_IMMICH_ALBUM_SOCKET", DEFAULT_IMMICH_ALBUM_SOCKET)


def load_immich_key() -> str:
    directory = os.environ.get("CREDENTIALS_DIRECTORY")
    if not directory:
        raise SystemExit(
            "photo-triage: CREDENTIALS_DIRECTORY is not set; the unit must LoadCredential immich-read-key"
        )
    path = Path(directory, "immich-read-key")
    if not path.is_file():
        raise SystemExit(f"photo-triage: missing Immich read key: {path}")
    value = path.read_text().strip()
    if not value:
        raise SystemExit(f"photo-triage: empty Immich read key: {path}")
    return value


def load_album_key() -> str:
    directory = os.environ.get("CREDENTIALS_DIRECTORY")
    if not directory:
        raise SystemExit(
            "photo-triage: CREDENTIALS_DIRECTORY is not set; the unit must "
            "LoadCredential immich-album-key"
        )
    path = Path(directory, "immich-album-key")
    if not path.is_file():
        raise SystemExit(f"photo-triage: missing Immich album key: {path}")
    value = path.read_text().strip()
    if not value:
        raise SystemExit(f"photo-triage: empty Immich album key: {path}")
    return value


def chunk_size(value: str) -> int:
    number = int(value)
    if not 1 <= number <= 1000:
        raise argparse.ArgumentTypeError("chunk must be between 1 and 1000")
    return number


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="photo-triage", description="Local photo triage for Immich"
    )
    parser.add_argument("--version", action="version", version=__version__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("doctor", help="check the data root and relay sockets")

    scan = commands.add_parser("scan", help="scan the Immich library into the local database")
    scan.add_argument("--page-size", type=int, default=PAGE_SIZE)
    scan.add_argument("--max-assets", type=int, default=None)

    coverage = commands.add_parser("coverage", help="print a scan generation's coverage")
    coverage.add_argument("--scan-id", type=int, default=None)

    requeue = commands.add_parser("requeue", help="reopen skipped assets in a scan generation")
    requeue.add_argument("--scan-id", type=int, default=None)
    requeue.add_argument("--reason", default=None)

    commands.add_parser("self-test", help="check the scoring model alias and vision")

    analyze = commands.add_parser("analyze", help="compute preview heuristics and duplicate groups")
    analyze.add_argument("--scan-id", type=int, default=None)
    analyze.add_argument("--threshold", type=int, default=PHASH_THRESHOLD)
    analyze.add_argument("--max-assets", type=int, default=None)

    decide = commands.add_parser("decide", help="turn scores and duplicates into decisions")
    decide.add_argument("--scan-id", type=int, default=None)
    decide.add_argument("--cap", type=int, default=None)
    decide.add_argument(
        "--out",
        default=None,
        help="write the membership export here "
        "(default: <data>/triage-membership-<scan-id>.json)",
    )
    decide.add_argument(
        "--dry-run", action="store_true", help="compute without writing the database or export"
    )
    decide.add_argument(
        "--allow-partial",
        action="store_true",
        help="decide a partial scan (failed and running scans are always rejected)",
    )

    albums = commands.add_parser("albums", help="reconcile decisions into Immich albums")
    album_commands = albums.add_subparsers(dest="album_command", required=True)
    sync = album_commands.add_parser("sync", help="diff and write the two triage albums")
    sync.add_argument("--scan-id", type=int, default=None)
    sync.add_argument("--export", default=None, help="membership export path")
    sync.add_argument("--dry-run", action="store_true", help="print the diff, call nothing")
    sync.add_argument(
        "--reconcile",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="re-read album counts after writing (default: on)",
    )
    sync.add_argument("--chunk", type=chunk_size, default=100)
    probe = album_commands.add_parser(
        "preflight", help="prove the album key's scopes with a probe asset"
    )
    probe.add_argument("--asset-id", required=True)
    album_commands.add_parser("status", help="print the local album snapshots")

    run = commands.add_parser("run", help="score the library (service only)")
    run.add_argument("--dev-fixtures", action="store_true", help=argparse.SUPPRESS)
    run.add_argument("--scan-id", type=int, default=None)
    run.add_argument("--max-assets", type=int, default=None)
    return parser


def doctor() -> int:
    root = data_dir()
    sockets = {
        "immich": Path(immich_socket()),
        "llm": Path(llm_socket()),
    }
    problems = []
    if not root.is_dir():
        problems.append(f"missing data dir: {root}")
    elif not os.access(root, os.W_OK):
        problems.append(f"data dir is not writable: {root}")
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
    print(f"ok data={root} immich={sockets['immich']} llm={sockets['llm']}")
    return 0


def scan_command(args: argparse.Namespace) -> int:
    database = Database(data_dir() / DB_NAME)
    try:
        client = ImmichClient(socket_path=immich_socket(), api_key=load_immich_key())
        scan_id = scan_library(
            client,
            database,
            page_size=args.page_size,
            max_assets=args.max_assets,
        )
        print(
            json.dumps(
                {
                    "scan_id": scan_id,
                    "coverage": database.coverage(scan_id),
                    "duplicates": database.duplicates_summary(scan_id),
                },
                sort_keys=True,
            )
        )
        return 0
    except ImmichError as error:
        print(f"photo-triage: {error}", file=sys.stderr)
        return 1
    except Exception as error:
        print(f"photo-triage: {error}", file=sys.stderr)
        return 1
    finally:
        database.close()


def coverage_command(args: argparse.Namespace) -> int:
    database = Database(data_dir() / DB_NAME)
    try:
        scan_id = args.scan_id if args.scan_id is not None else database.latest_scan()
        if scan_id is None:
            print("photo-triage: no scans in the database", file=sys.stderr)
            return 1
        state = database.scan_state(scan_id)
        if state is None:
            print(f"photo-triage: no scan {scan_id}", file=sys.stderr)
            return 1
        print(json.dumps(database.coverage(scan_id), sort_keys=True))
        return 0
    finally:
        database.close()


def requeue_command(args: argparse.Namespace) -> int:
    database = Database(data_dir() / DB_NAME)
    try:
        scan_id = args.scan_id if args.scan_id is not None else database.latest_scan()
        if scan_id is None:
            print("photo-triage: no scans in the database", file=sys.stderr)
            return 1
        state = database.scan_state(scan_id)
        if state is None:
            print(f"photo-triage: no scan {scan_id}", file=sys.stderr)
            return 1
        count = database.requeue(scan_id, args.reason)
        print(json.dumps({"scan_id": scan_id, "requeued": count}, sort_keys=True))
        return 0
    finally:
        database.close()


def self_test_command() -> int:
    model = os.environ.get("PHOTO_TRIAGE_MODEL", MODEL_ALIAS)
    client = LLMClient(socket_path=llm_socket(), model=model)
    try:
        client.wait_ready()
        client.vision_self_test()
    except LLMError as error:
        print(f"photo-triage: {error}", file=sys.stderr)
        return 1
    print(json.dumps({"ok": "vision self-test"}, sort_keys=True))
    return 0


def decide_command(args: argparse.Namespace) -> int:
    database = Database(data_dir() / DB_NAME)
    try:
        scan_id = (
            args.scan_id if args.scan_id is not None else database.latest_complete_scan()
        )
        if scan_id is None:
            print("photo-triage: no completed scan in the database", file=sys.stderr)
            return 1
        if args.cap is not None and not 0 <= args.cap <= POLICY["delete_cap"]:
            print(
                f"photo-triage: cap must be between 0 and {POLICY['delete_cap']}",
                file=sys.stderr,
            )
            return 2
        export_path = (
            Path(args.out)
            if args.out is not None
            else data_dir() / f"triage-membership-{scan_id}.json"
        )
        result = decide_scan(
            database,
            scan_id,
            cap=args.cap,
            export_path=export_path,
            allow_partial=args.allow_partial,
            dry_run=args.dry_run,
        )
        summary = {
            key: result[key]
            for key in (
                "scan_id",
                "run_id",
                "policy_version",
                "policy_fingerprint",
                "manifest_sha256",
                "safe_to_delete",
                "cap",
                "counts",
            )
        }
        summary["export"] = None if args.dry_run else str(export_path)
        summary["dry_run"] = bool(args.dry_run)
        print(json.dumps(summary, sort_keys=True))
        return 0
    except Exception as error:
        print(f"photo-triage: {error}", file=sys.stderr)
        return 1
    finally:
        database.close()


def analyze_command(args: argparse.Namespace) -> int:
    database = Database(data_dir() / DB_NAME)
    try:
        scan_id = args.scan_id if args.scan_id is not None else database.latest_scan()
        if scan_id is None:
            print("photo-triage: no completed scan in the database", file=sys.stderr)
            return 1
        if not 0 <= args.threshold <= 32:
            print("photo-triage: threshold must be between 0 and 32", file=sys.stderr)
            return 2
        immich = ImmichClient(socket_path=immich_socket(), api_key=load_immich_key())
        immich.assert_read_permissions()
        stats = analyze_scan(
            immich,
            database,
            scan_id,
            threshold=args.threshold,
            max_assets=args.max_assets,
        )
        print(json.dumps(stats, sort_keys=True))
        if stats["assets"] > 0 and stats["previews"] == 0:
            print("photo-triage: no previews were analyzed", file=sys.stderr)
            return 1
        return 0
    except Exception as error:
        print(f"photo-triage: {error}", file=sys.stderr)
        return 1
    finally:
        database.close()


def run(dev_fixtures: bool, scan_id_arg: int | None = None, max_assets: int | None = None) -> int:
    if not dev_fixtures and os.environ.get("PHOTO_TRIAGE_UNIT") != "1":
        print(
            "photo-triage: run through the service, or pass --dev-fixtures",
            file=sys.stderr,
        )
        return 2
    database = Database(data_dir() / DB_NAME)
    try:
        scan_id = scan_id_arg if scan_id_arg is not None else database.latest_scan()
        if scan_id is None:
            print("photo-triage: no completed scan in the database", file=sys.stderr)
            return 1
        immich = ImmichClient(socket_path=immich_socket(), api_key=load_immich_key())
        model = LLMClient(
            socket_path=llm_socket(),
            model=os.environ.get("PHOTO_TRIAGE_MODEL", MODEL_ALIAS),
        )
        model.wait_ready()
        model.vision_self_test()
        stats = score_library(immich, model, database, scan_id, max_assets=max_assets)
        print(json.dumps(stats, sort_keys=True))
        if stats["pending"] > 0 and stats["scored"] + stats["reused"] == 0:
            print("photo-triage: no assets were scored", file=sys.stderr)
            return 1
        return 0
    except (ImmichError, LLMError, ScorerError) as error:
        print(f"photo-triage: {error}", file=sys.stderr)
        return 1
    finally:
        database.close()


def albums_command(args: argparse.Namespace) -> int:
    database = Database(data_dir() / DB_NAME)
    try:
        if args.album_command == "status":
            print(json.dumps(album_status(database), sort_keys=True))
            return 0
        if args.album_command == "preflight":
            client = ImmichClient(
                socket_path=album_socket(), api_key=load_album_key()
            )
            run_id = database.start_run("albums-preflight")
            try:
                result = preflight(client, probe_asset_id=args.asset_id)
            except BaseException as error:
                database.finish_run(run_id, "failed", {"error": str(error)})
                raise
            database.finish_run(run_id, "complete", result)
            print(json.dumps(result, sort_keys=True))
            return 0
        scan_id = args.scan_id
        if args.export is not None:
            path = Path(args.export)
        else:
            if scan_id is None:
                scan_id = database.latest_complete_scan()
            if scan_id is None:
                print("photo-triage: no completed scan in the database", file=sys.stderr)
                return 1
            path = data_dir() / f"triage-membership-{scan_id}.json"
        export = load_export(database, path)
        if args.scan_id is not None and export["scan_id"] != args.scan_id:
            raise AlbumError(
                f"export belongs to scan {export['scan_id']}, not {args.scan_id}"
            )
        client = None
        if not args.dry_run:
            client = ImmichClient(
                socket_path=album_socket(), api_key=load_album_key()
            )
        run_id = None if args.dry_run else database.start_run("albums", export["scan_id"])
        try:
            reports = sync_export(
                database,
                client,
                export,
                path=path,
                dry_run=args.dry_run,
                reconcile=args.reconcile,
                chunk=args.chunk,
            )
        except BaseException as error:
            if run_id is not None:
                database.finish_run(
                    run_id, "failed", {"decide_run_id": export["run_id"], "error": str(error)}
                )
            raise
        reconciled = all(report.reconciled for report in reports)
        if run_id is not None:
            database.finish_run(
                run_id,
                "complete" if reconciled else "failed",
                {
                    "decide_run_id": export["run_id"],
                    "reports": [report.as_dict() for report in reports],
                },
            )
        print(json.dumps({"reports": [report.as_dict() for report in reports]}, sort_keys=True))
        return 0 if reconciled else 1
    except (AlbumError, ImmichError) as error:
        print(f"photo-triage: {error}", file=sys.stderr)
        return 1
    finally:
        database.close()


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.command == "doctor":
        return doctor()
    if args.command == "scan":
        return scan_command(args)
    if args.command == "coverage":
        return coverage_command(args)
    if args.command == "requeue":
        return requeue_command(args)
    if args.command == "self-test":
        return self_test_command()
    if args.command == "analyze":
        return analyze_command(args)
    if args.command == "decide":
        return decide_command(args)
    if args.command == "albums":
        return albums_command(args)
    if args.command == "run":
        return run(args.dev_fixtures, args.scan_id, args.max_assets)
    return 2
