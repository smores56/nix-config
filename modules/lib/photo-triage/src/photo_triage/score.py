"""Score scanned assets with the local vision model and store idempotent verdicts."""

from __future__ import annotations

import base64
import hashlib
import io
import json
import logging
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
DETAIL_MAX_CHARS = 120
# llama.cpp phrases we can name without persisting its response body.
MODEL_FAILURE_CLASSES = (
    ("exceeds the available context size", "context-overflow"),
    ("context size", "context-overflow"),
    ("failed to load image", "image"),
    ("image", "image"),
    ("jinja", "template"),
    ("template", "template"),
    ("grammar", "grammar"),
    ("json_schema", "grammar"),
)
# LLMError text this client raises itself; anything else may be peer-controlled.
OWN_MODEL_MESSAGES = (
    "scoring model hit max_tokens",
    "scoring model response is not JSON",
    "scoring model response is not an object",
    "scoring model returned no choices",
    "scoring model choice is not an object",
    "scoring model returned empty content",
)

logger = logging.getLogger(__name__)
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
        raise PreviewError("too-large")
    try:
        image = Image.open(io.BytesIO(data)).convert("RGB")
        image.thumbnail((PREVIEW_MAX_EDGE, PREVIEW_MAX_EDGE), Image.Resampling.LANCZOS)
        buffer = io.BytesIO()
        image.save(buffer, "JPEG", quality=PREVIEW_QUALITY)
    except (OSError, ValueError, Image.DecompressionBombError) as error:
        # Pillow's text embeds object addresses; keep a stable code instead.
        raise PreviewError("decode") from error
    normalized = buffer.getvalue()
    return normalized, hashlib.sha256(normalized).hexdigest()


def parse_score(content: str) -> dict[str, Any]:
    try:
        data = json.loads(content)
    except (TypeError, json.JSONDecodeError) as error:
        # Structural only: the model's prose is about the photo. Length and
        # brace balance separate a truncated reply from prose or an error.
        balance = "none" if not ("{" in content or "}" in content) else (
            "balanced"
            if content.count("{") == content.count("}")
            else "unbalanced"
        )
        raise ScoreSchemaError(
            f"model content is not JSON ({_length_class(content)}, braces={balance})"
        ) from error
    if not isinstance(data, dict):
        raise ScoreSchemaError(f"model content is not an object ({type(data).__name__})")
    if set(data) != {"verdict", "defects", "interest", "confidence"}:
        expected = {"verdict", "defects", "interest", "confidence"}
        raise ScoreSchemaError(
            "model content has unexpected keys "
            f"(missing={len(expected - set(data))}, extra={len(set(data) - expected)})"
        )
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
) -> tuple[bytes | None, int]:
    status = 0
    for attempt in range(3):
        try:
            return immich.thumbnail(asset_id), 0
        except ImmichError as error:
            status = error.status
            if error.transient and attempt < 2:
                sleep(2**attempt)
                continue
            return None, status
    return None, status


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


def _length_class(content: str) -> str:
    size = len(content)
    if size == 0:
        return "len=0"
    if size < 64:
        return "len=1-63"
    if size < 256:
        return "len=64-255"
    return "len=256+"


def _detail(text: object) -> str:
    """Bound and sanitize a failure message for the database and the journal."""
    printable = "".join(
        character if character.isprintable() else " " for character in str(text)
    )
    return " ".join(printable.split())[:DETAIL_MAX_CHARS]


def _model_failure_detail(error: LLMError) -> str:
    """Name the failure class; the server's body never reaches the database."""
    text = str(error)
    if text.startswith(OWN_MODEL_MESSAGES):
        return _detail(text)
    if not error.status:
        # A zero status with foreign text (BadStatusLine) is peer-controlled.
        return "model http=0 class=transport"
    lowered = text.lower()
    for needle, name in MODEL_FAILURE_CLASSES:
        if needle in lowered:
            return f"model http={error.status} class={name}"
    return f"model http={error.status} class=other"


def _skip(
    database: Database, scan_id: int, asset_id: str, reason: str, detail: object
) -> None:
    database.mark_scan_asset(scan_id, asset_id, "skipped", reason, _detail(detail))
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
            raw, preview_status = _fetch_preview(immich, asset_id, sleep)
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
                _skip(
                    database,
                    scan_id,
                    asset_id,
                    "preview",
                    "immich transport" if not preview_status else f"immich http={preview_status}",
                )
                stats["skipped"] += 1
                continue
            try:
                normalized, digest = normalize_preview(raw)
            except PreviewError as error:
                database.record_preview(
                    asset_id,
                    state="skipped",
                    reason="preview",
                    generator_id=PREVIEW_GENERATOR,
                    bytes_sha256=None,
                    asset_checksum=revision[0],
                    asset_updated_at=revision[1],
                )
                _skip(
                    database,
                    scan_id,
                    asset_id,
                    "preview",
                    f"preview {error}",
                )
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
                _skip(database, scan_id, asset_id, "model", _model_failure_detail(error))
                stats["skipped"] += 1
                continue
            except ScoreSchemaError as error:
                _skip(database, scan_id, asset_id, "schema", error)
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
        if stats["skipped"]:
            # One aggregate line: per-asset warnings would flood the journal.
            # Totals are per generation, so a bounded benchmark repeats them.
            coverage = database.coverage(scan_id)
            logger.warning(
                "photo-triage skips scan=%s reasons=%s details=%s",
                scan_id,
                json.dumps(coverage["reasons"], sort_keys=True),
                json.dumps(coverage["details"], sort_keys=True),
            )
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
