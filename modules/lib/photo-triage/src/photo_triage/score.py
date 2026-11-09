"""Score scanned assets with the local vision model and store idempotent verdicts."""

from __future__ import annotations

import base64
import hashlib
import io
import json
import os
import time
from typing import Any, Callable

from PIL import Image

from .db import Database
from .immich import ImmichClient, ImmichError
from .model import LLMClient, LLMError

PREVIEW_MAX_EDGE = 1024
PREVIEW_QUALITY = 85
PREVIEW_GENERATOR = f"immich-preview-v1-{PREVIEW_MAX_EDGE}-{PREVIEW_QUALITY}"
PREVIEW_MAX_BYTES = 32 * 1024 * 1024
Image.MAX_IMAGE_PIXELS = 50_000_000
MAX_MODEL_ATTEMPTS = 3
VERDICTS = ("keep", "review", "delete")
DEFECTS = (
    "blur",
    "dark",
    "bright",
    "obstruction",
    "screenshot",
    "document",
    "duplicate",
    "accidental",
    "low_res",
)

SCHEMA = {
    "type": "json_schema",
    "json_schema": {
        "name": "photo_triage_verdict",
        "strict": True,
        "schema": {
            "type": "object",
            "additionalProperties": False,
            "properties": {
                "verdict": {"type": "string", "enum": list(VERDICTS)},
                "defects": {
                    "type": "array",
                    "items": {"type": "string", "enum": list(DEFECTS)},
                    "uniqueItems": True,
                },
                "interest": {"type": "integer", "minimum": 1, "maximum": 5},
                "confidence": {"type": "number", "minimum": 0, "maximum": 1},
            },
            "required": ["verdict", "defects", "interest", "confidence"],
        },
    },
}

PROMPT = (
    "You are triaging a personal photo library for deletion candidates. "
    "Judge only technical quality and archival interest. "
    "Never describe or judge people's appearance, bodies, age, race, or attractiveness. "
    "Interest means archival value, not beauty. "
    "Use only the JSON schema. If you are unsure, choose keep."
)
PROMPT_VERSION = hashlib.sha256(
    (PROMPT + json.dumps(SCHEMA, sort_keys=True)).encode("utf-8")
).hexdigest()[:12]


class ScoreSchemaError(Exception):
    pass


class PreviewError(Exception):
    pass


class ScorerError(Exception):
    pass


def normalize_preview(data: bytes) -> tuple[bytes, str]:
    if len(data) > PREVIEW_MAX_BYTES:
        raise PreviewError("preview is too large")
    try:
        image = Image.open(io.BytesIO(data)).convert("RGB")
        image.thumbnail((PREVIEW_MAX_EDGE, PREVIEW_MAX_EDGE), Image.Resampling.LANCZOS)
        buffer = io.BytesIO()
        image.save(buffer, "JPEG", quality=PREVIEW_QUALITY)
    except (OSError, ValueError, Image.DecompressionBombError) as error:
        raise PreviewError(str(error)) from error
    normalized = buffer.getvalue()
    return normalized, hashlib.sha256(normalized).hexdigest()


def parse_score(content: str) -> dict[str, Any]:
    try:
        data = json.loads(content)
    except (TypeError, json.JSONDecodeError) as error:
        raise ScoreSchemaError("model content is not JSON") from error
    if not isinstance(data, dict):
        raise ScoreSchemaError("model content is not an object")
    if set(data) != {"verdict", "defects", "interest", "confidence"}:
        raise ScoreSchemaError("model content has unexpected keys")
    verdict = data["verdict"]
    if verdict not in VERDICTS:
        raise ScoreSchemaError("invalid verdict")
    defects = data["defects"]
    if not isinstance(defects, list) or any(defect not in DEFECTS for defect in defects):
        raise ScoreSchemaError("invalid defects")
    if len(set(defects)) != len(defects):
        raise ScoreSchemaError("duplicate defects")
    interest = data["interest"]
    if isinstance(interest, bool) or not isinstance(interest, int) or not 1 <= interest <= 5:
        raise ScoreSchemaError("invalid interest")
    confidence = data["confidence"]
    if isinstance(confidence, bool) or not isinstance(confidence, (int, float)):
        raise ScoreSchemaError("invalid confidence")
    if not 0 <= float(confidence) <= 1:
        raise ScoreSchemaError("confidence out of range")
    return data


def _fetch_preview(
    immich: ImmichClient, asset_id: str, sleep: Callable[[float], None]
) -> bytes | None:
    for attempt in range(3):
        try:
            return immich.thumbnail(asset_id)
        except ImmichError as error:
            if error.transient and attempt < 2:
                sleep(2**attempt)
                continue
            return None
    return None


def _messages(normalized: bytes) -> list[dict[str, Any]]:
    encoded = base64.b64encode(normalized).decode()
    return [
        {"role": "system", "content": PROMPT},
        {
            "role": "user",
            "content": [
                {"type": "text", "text": "Triage this photo."},
                {
                    "type": "image_url",
                    "image_url": {"url": f"data:image/jpeg;base64,{encoded}"},
                },
            ],
        },
    ]


def _skip(database: Database, scan_id: int, asset_id: str, reason: str) -> None:
    database.mark_scan_asset(scan_id, asset_id, "skipped", reason)
    database.commit()


def score_library(
    immich: ImmichClient,
    model: LLMClient,
    database: Database,
    scan_id: int,
    *,
    max_assets: int | None = None,
    sleep: Callable[[float], None] = time.sleep,
    model_id: str | None = None,
    mmproj_sha256: str | None = None,
    prompt_version: str = PROMPT_VERSION,
) -> dict[str, int]:
    resolved_model = model_id or os.environ.get("PHOTO_TRIAGE_MODEL_ID", model.model)
    resolved_mmproj = mmproj_sha256 or os.environ.get(
        "PHOTO_TRIAGE_MMPROJ_SHA256", "unknown"
    )
    run_id = database.start_run("score", scan_id)
    stats = {"pending": 0, "scored": 0, "skipped": 0, "reused": 0, "model_calls": 0}
    try:
        asset_ids = database.pending_assets(scan_id, max_assets)
        stats["pending"] = len(asset_ids)
        for asset_id in asset_ids:
            revision = database.asset_revision(asset_id)
            cached = database.preview(asset_id)
            if (
                cached is not None
                and cached["state"] == "ready"
                and cached["bytes_sha256"]
                and cached["generator_id"] == PREVIEW_GENERATOR
                and cached["asset_checksum"] == revision[0]
                and cached["asset_updated_at"] == revision[1]
            ):
                if database.active_score(
                    asset_id,
                    cached["bytes_sha256"],
                    resolved_model,
                    resolved_mmproj,
                    prompt_version,
                ):
                    database.mark_scan_asset(scan_id, asset_id, "reused")
                    database.commit()
                    stats["reused"] += 1
                    continue
            raw = _fetch_preview(immich, asset_id, sleep)
            if raw is None:
                database.record_preview(
                    asset_id,
                    state="skipped",
                    reason="preview",
                    generator_id=PREVIEW_GENERATOR,
                    bytes_sha256=None,
                    asset_checksum=revision[0],
                    asset_updated_at=revision[1],
                )
                _skip(database, scan_id, asset_id, "preview")
                stats["skipped"] += 1
                continue
            try:
                normalized, digest = normalize_preview(raw)
            except PreviewError:
                database.record_preview(
                    asset_id,
                    state="skipped",
                    reason="preview",
                    generator_id=PREVIEW_GENERATOR,
                    bytes_sha256=None,
                    asset_checksum=revision[0],
                    asset_updated_at=revision[1],
                )
                _skip(database, scan_id, asset_id, "preview")
                stats["skipped"] += 1
                continue
            database.record_preview(
                asset_id,
                state="ready",
                reason=None,
                generator_id=PREVIEW_GENERATOR,
                bytes_sha256=digest,
                asset_checksum=revision[0],
                asset_updated_at=revision[1],
            )
            if database.active_score(
                asset_id, digest, resolved_model, resolved_mmproj, prompt_version
            ):
                database.mark_scan_asset(scan_id, asset_id, "reused")
                database.commit()
                stats["reused"] += 1
                continue
            messages = _messages(normalized)
            score = None
            raw_sha = ""
            try:
                for attempt in range(MAX_MODEL_ATTEMPTS):
                    stats["model_calls"] += 1
                    try:
                        response = model.chat(
                            messages, response_format=SCHEMA, max_tokens=300
                        )
                        content = model.content(response)
                        score = parse_score(content)
                        raw_sha = hashlib.sha256(content.encode("utf-8")).hexdigest()
                        break
                    except ScoreSchemaError:
                        if attempt + 1 >= MAX_MODEL_ATTEMPTS:
                            raise
                        sleep(1)
                    except LLMError as error:
                        if not error.transient or attempt + 1 >= MAX_MODEL_ATTEMPTS:
                            raise
                        sleep(2**attempt)
            except LLMError as error:
                if error.transient:
                    raise ScorerError(f"scoring model unavailable: {error}") from error
                _skip(database, scan_id, asset_id, "model")
                stats["skipped"] += 1
                continue
            except ScoreSchemaError:
                _skip(database, scan_id, asset_id, "schema")
                stats["skipped"] += 1
                continue
            if score is None:
                raise ScorerError("scoring produced no verdict")
            database.record_score(
                asset_id=asset_id,
                preview_sha256=digest,
                model_id=resolved_model,
                mmproj_sha256=resolved_mmproj,
                prompt_version=prompt_version,
                verdict=str(score["verdict"]),
                defects=list(score["defects"]),
                interest=int(score["interest"]),
                confidence=float(score["confidence"]),
                raw_sha256=raw_sha,
            )
            database.mark_scan_asset(scan_id, asset_id, "scored")
            database.commit()
            stats["scored"] += 1
        state = "complete" if stats["scored"] + stats["reused"] > 0 else "failed"
        database.finish_run(run_id, state, stats)
        return stats
    except BaseException:
        try:
            database.rollback()
            database.finish_run(run_id, "failed", stats)
        except Exception:
            pass
        raise
