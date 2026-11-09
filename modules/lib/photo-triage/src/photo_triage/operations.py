"""Service orchestration, progress status, and throughput benchmarking."""

from __future__ import annotations

import json
import os
import socket
import threading
import time
from datetime import datetime
from pathlib import Path
from typing import Any

from .albums import album_status
from .db import Database
from .decisions import decide_scan
from .duplicates import HEURISTICS_VERSION, analyze_scan
from .immich import ImmichClient
from .model import LLMClient
from .scan import PAGE_SIZE, scan_library
from .score import PREVIEW_GENERATOR, score_library


class Notifier:
    """Minimal sd_notify client; a no-op outside systemd."""

    def __init__(self, address: str | None = None) -> None:
        self.address = address or os.environ.get("NOTIFY_SOCKET")
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def send(self, message: str) -> None:
        if not self.address:
            return
        address = self.address
        if address.startswith("@"):
            address = "\0" + address[1:]
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as sock:
                sock.sendto(message.encode("utf-8"), address)
        except OSError:
            pass

    def start_watchdog(self, interval: float = 60.0) -> None:
        if not self.address:
            return
        self._stop = threading.Event()
        if self._thread is not None:
            return

        def loop() -> None:
            while not self._stop.wait(interval):
                self.send("WATCHDOG=1")

        self._thread = threading.Thread(target=loop, daemon=True)
        self._thread.start()

    def stop_watchdog(self) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=1)
            self._thread = None


def orchestrate(
    immich: ImmichClient,
    model: LLMClient,
    database: Database,
    *,
    scan_id: int | None = None,
    max_assets: int | None = None,
    page_size: int = PAGE_SIZE,
    export_path: str | Path | None = None,
    export_dir: str | Path | None = None,
    notifier: Notifier | None = None,
    sleep: Any = time.sleep,
) -> dict[str, Any]:
    notifier = notifier or Notifier()
    notifier.send("STATUS=scanning")
    try:
        if scan_id is None:
            scan_id = scan_library(immich, database, page_size=page_size, sleep=sleep)
        elif database.scan_state(scan_id) != "complete":
            raise ValueError(f"scan {scan_id} is not complete")

        pending = database.pending_assets(scan_id)
        notifier.send(f"STATUS=scoring scan {scan_id} ({len(pending)} pending)")
        if pending:
            model.wait_ready()
            model.vision_self_test()
        notifier.send("READY=1")
        notifier.start_watchdog()
        score_stats: dict[str, int] = {
            "pending": len(pending),
            "scored": 0,
            "skipped": 0,
            "reused": 0,
            "model_calls": 0,
        }
        if pending:
            score_stats = score_library(
                immich,
                model,
                database,
                scan_id,
                max_assets=max_assets,
                sleep=sleep,
            )
        remaining = database.pending_assets(scan_id)
        if remaining and max_assets is not None:
            return {
                "scan_id": scan_id,
                "stopped": "max_assets",
                "score": score_stats,
                "remaining": len(remaining),
            }
        if remaining:
            raise ValueError("scoring is incomplete; rerun to finish")

        notifier.send("STATUS=analyzing previews")
        if not database.analysis_ready(
            scan_id,
            generator_id=PREVIEW_GENERATOR,
            heuristics_version=HEURISTICS_VERSION,
        ):
            analyze_stats = analyze_scan(immich, database, scan_id, sleep=sleep)
        else:
            analyze_stats = {"assets": 0, "previews": 0, "skipped": 0,
                             "exact_groups": 0, "near_groups": 0, "immich_groups": 0}

        notifier.send("STATUS=deciding")
        destination = Path(export_path) if export_path is not None else None
        if destination is None and export_dir is not None:
            destination = Path(export_dir) / f"triage-membership-{scan_id}.json"
        decision = decide_scan(database, scan_id, export_path=destination)
        notifier.send("STATUS=decided; calibration and album sync await sign-off")
        return {
            "scan_id": scan_id,
            "score": score_stats,
            "analyze": analyze_stats,
            "decide": decision["counts"],
            "export": str(destination) if destination is not None else None,
        }
    finally:
        notifier.stop_watchdog()
        notifier.send("STOPPING=1")


def _seconds(started: str | None, finished: str | None) -> float | None:
    if not started or not finished:
        return None
    try:
        start = datetime.fromisoformat(started.replace("Z", "+00:00"))
        end = datetime.fromisoformat(finished.replace("Z", "+00:00"))
    except ValueError:
        return None
    return max(0.0, (end - start).total_seconds())


def _eta(pending: int, run: Any) -> float | None:
    if pending <= 0 or run is None:
        return None
    duration = _seconds(run["started_at"], run["finished_at"])
    if not duration:
        return None
    stats = json.loads(run["stats_json"] or "{}")
    done = int(stats.get("scored", 0)) + int(stats.get("reused", 0))
    if done <= 0:
        return None
    return pending / (done / duration)


def status(database: Database) -> dict[str, Any]:
    scan_id = database.latest_scan()
    if scan_id is None:
        return {"scan_id": None, "state": "no-scan", "resume_safe": True}
    coverage = database.coverage(scan_id)
    states = coverage["states"]
    images = len(database.scan_image_assets(scan_id))
    scored = int(states.get("scored", 0)) + int(states.get("reused", 0))
    pending = len(database.pending_assets(scan_id))
    analysis = database.analysis(scan_id)
    decide_run = database.latest_decide_run(scan_id)
    report = database.latest_calibration_report(scan_id)
    report_stats = (
        json.loads(report["stats_json"] or "{}") if report is not None else {}
    )
    score_run = database.connection.execute(
        "SELECT * FROM runs WHERE kind = 'score' AND scan_id = ? AND state = 'complete' "
        "ORDER BY id DESC LIMIT 1",
        (scan_id,),
    ).fetchone()
    return {
        "scan_id": scan_id,
        "state": database.scan_state(scan_id),
        "images": images,
        "scored": scored,
        "pending": pending,
        "coverage": coverage["states"],
        "skipped_reasons": coverage["reasons"],
        "previews": database.preview_count(),
        "analysis": {
            "ready": database.analysis_ready(
                scan_id,
                generator_id=PREVIEW_GENERATOR,
                heuristics_version=HEURISTICS_VERSION,
            ),
            "generation": analysis["generation"] if analysis is not None else None,
        },
        "decide_run_id": decide_run,
        "calibration": {
            "state": report["state"] if report is not None else None,
            "passed": bool(report_stats.get("go_no_go", {}).get("passed")),
        },
        "albums": album_status(database),
        "eta_seconds": {
            "score": _eta(pending, score_run),
        },
        "resume_safe": True,
    }


def benchmark(
    immich: ImmichClient,
    model: LLMClient,
    database: Database,
    *,
    count: int = 10,
    scan_id: int | None = None,
    sleep: Any = time.sleep,
) -> dict[str, Any]:
    if count < 1:
        raise ValueError("count must be positive")
    scan_id = scan_id or database.latest_complete_scan()
    if scan_id is None:
        raise ValueError("no complete scan to benchmark")
    if not database.pending_assets(scan_id):
        raise ValueError("no pending assets; scan a new generation first")
    model.wait_ready()
    model.vision_self_test()
    started = time.monotonic()
    stats = score_library(
        immich, model, database, scan_id, max_assets=count, sleep=sleep
    )
    elapsed = max(0.001, time.monotonic() - started)
    done = int(stats["scored"]) + int(stats["reused"])
    return {
        "scan_id": scan_id,
        "scored": int(stats["scored"]),
        "reused": int(stats["reused"]),
        "model_calls": int(stats["model_calls"]),
        "seconds": round(elapsed, 3),
        "assets_per_minute": round(done / elapsed * 60, 2),
    }


def benchmark_history(database: Database) -> dict[str, Any]:
    rows = database.connection.execute(
        "SELECT scan_id, started_at, finished_at, stats_json FROM runs "
        "WHERE kind = 'score' AND state = 'complete' ORDER BY id DESC LIMIT 20"
    ).fetchall()
    runs = []
    for row in rows:
        duration = _seconds(row["started_at"], row["finished_at"])
        stats = json.loads(row["stats_json"] or "{}")
        done = int(stats.get("scored", 0)) + int(stats.get("reused", 0))
        if duration and done:
            runs.append(
                {
                    "scan_id": row["scan_id"],
                    "assets": done,
                    "seconds": round(duration, 3),
                    "assets_per_minute": round(done / duration * 60, 2),
                }
            )
    return {"runs": runs}
