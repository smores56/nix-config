"""Deterministic synthetic photo corpus for the photo-triage test suite.

The corpus is rendered at test time; no image is committed. Tests use it to
exercise the heuristics and the VLM adapter without touching a real library.
"""

from __future__ import annotations

import base64
import hashlib
import io
import random
from datetime import datetime, timedelta, timezone
from pathlib import Path

from PIL import Image, ImageDraw, ImageEnhance, ImageFilter, ImageFont, ImageStat

# Pillow moved the resampling constants; keep the module importable on old and new.
RESAMPLE = getattr(Image, "Resampling", Image).LANCZOS
FONT = ImageFont.load_default()


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _pixels(image: Image.Image) -> list[int]:
    """Pillow 12 renames getdata; keep the probes warning-free on both."""
    getter = getattr(image, "get_flattened_data", None)
    return list(getter()) if getter is not None else list(image.getdata())


def _scene(seed: int, size: tuple[int, int] = (1024, 768)) -> Image.Image:
    """A structured, photo-like image: gradient plus large shapes, no noise."""
    width, height = size
    rng = random.Random(seed)
    image = Image.new("RGB", size)
    draw = ImageDraw.Draw(image)
    flip = rng.random() < 0.5
    for y in range(height):
        t = y / max(height - 1, 1)
        if flip:
            t = 1 - t
        luma = int(25 + 210 * t)
        color = (int(luma * 0.55), int(luma * 0.8), luma)
        draw.line([(0, y), (width - 1, y)], fill=color)
    for _ in range(8):
        x0 = rng.randint(-120, width - 60)
        y0 = rng.randint(-120, height - 60)
        w = rng.randint(90, 340)
        h = rng.randint(70, 280)
        color = (rng.randint(20, 240), rng.randint(20, 240), rng.randint(20, 240))
        if rng.random() < 0.5:
            draw.ellipse([x0, y0, x0 + w, y0 + h], fill=color)
        else:
            draw.rectangle([x0, y0, x0 + w, y0 + h], fill=color)
    draw.line(
        [(0, int(height * 0.62)), (width - 1, int(height * 0.55))],
        fill=(20, 20, 25),
        width=6,
    )
    return image


def _screenshot() -> Image.Image:
    image = Image.new("RGB", (1024, 768), (245, 245, 245))
    draw = ImageDraw.Draw(image)
    draw.rectangle([0, 0, 1024, 80], fill=(30, 30, 40))
    draw.text((24, 24), "Inbox", fill=(255, 255, 255), font=FONT)
    for index in range(8):
        y = 110 + index * 72
        draw.rectangle([40, y, 300, y + 16], fill=(60, 60, 70))
        draw.rectangle([40, y + 24, 900, y + 34], fill=(180, 180, 190))
        draw.rectangle([40, y + 42, 700, y + 50], fill=(200, 200, 210))
    return image


def _document() -> Image.Image:
    image = Image.new("RGB", (1024, 768), (250, 250, 250))
    draw = ImageDraw.Draw(image)
    draw.rectangle([80, 70, 430, 96], fill=(60, 60, 60))
    rng = random.Random(99)
    for index in range(24):
        y = 130 + index * 25
        draw.rectangle([80, y, 80 + rng.randint(300, 850), y + 8], fill=(85, 85, 85))
    return image


def _obstructed(image: Image.Image) -> Image.Image:
    out = image.copy()
    draw = ImageDraw.Draw(out)
    draw.ellipse([180, 130, 840, 660], fill=(8, 8, 8))
    return out


def _jpeg_bytes(image: Image.Image, quality: int) -> bytes:
    buffer = io.BytesIO()
    image.save(buffer, "JPEG", quality=quality)
    return buffer.getvalue()


def dhash(image: Image.Image, size: int = 8) -> int:
    """A 64-bit difference hash; deterministic and dependency-free.

    This is a corpus probe, not the package's DCT pHash; tests must not treat
    it as the production algorithm.
    """
    gray = image.convert("L").resize((size + 1, size), RESAMPLE)
    pixels = _pixels(gray)
    bits = 0
    for row in range(size):
        base = row * (size + 1)
        for column in range(size):
            bits = (bits << 1) | int(pixels[base + column] > pixels[base + column + 1])
    return bits


def hamming(left: int, right: int) -> int:
    return (left ^ right).bit_count()


def mean_luma(image: Image.Image) -> float:
    return float(ImageStat.Stat(image.convert("L")).mean[0])


def edge_energy(image: Image.Image) -> float:
    edges = image.convert("L").filter(ImageFilter.FIND_EDGES)
    return float(ImageStat.Stat(edges).var[0])


def white_fraction(image: Image.Image, threshold: int = 235) -> float:
    gray = image.convert("L")
    pixels = _pixels(gray)
    return sum(1 for value in pixels if value >= threshold) / len(pixels)


def dark_fraction(image: Image.Image, threshold: int = 40) -> float:
    gray = image.convert("L")
    pixels = _pixels(gray)
    return sum(1 for value in pixels if value < threshold) / len(pixels)


def generate_corpus(root: str | Path) -> dict[str, dict]:
    """Render every fixture under *root* and return its manifest.

    Every defect fixture uses its own scene seed so only the deliberate
    ``duplicate-a``/``duplicate-b`` pair is perceptually near; the manifest
    records the defects and a nominal interest for the tests to check.
    """
    root = Path(root)
    root.mkdir(parents=True, exist_ok=True)
    duplicate_source = _scene(7)
    blur_source = _scene(21)
    dark_source = _scene(31)
    bright_source = _scene(41)
    obstructed_source = _scene(51)
    tiny_source = _scene(61)
    photos: dict[str, dict] = {}

    def add(
        photo_id: str,
        image: Image.Image,
        kind: str,
        defects: list[str],
        interest: int,
        quality: int = 90,
    ) -> None:
        path = root / f"{photo_id}.jpg"
        path.write_bytes(_jpeg_bytes(image, quality))
        photos[photo_id] = {
            "id": photo_id,
            "kind": kind,
            "path": str(path),
            "width": image.width,
            "height": image.height,
            "sha256": _sha256(path),
            "expected_defects": defects,
            "expected_interest": interest,
        }

    add("keep", _scene(11), "keep", [], 4)
    add("blur", blur_source.filter(ImageFilter.GaussianBlur(8)), "blur", ["blur"], 2)
    add("dark", ImageEnhance.Brightness(dark_source).enhance(0.12), "dark", ["dark"], 2)
    add("bright", ImageEnhance.Brightness(bright_source).enhance(2.8), "bright", ["bright"], 2)
    add("duplicate-a", duplicate_source, "duplicate", ["duplicate"], 2)
    add(
        "duplicate-b",
        duplicate_source.resize((819, 614), RESAMPLE),
        "duplicate",
        ["duplicate"],
        2,
        quality=60,
    )
    add("screenshot", _screenshot(), "screenshot", ["screenshot"], 1)
    add("document", _document(), "document", ["document"], 1)
    add("obstructed", _obstructed(obstructed_source), "obstructed", ["obstruction"], 2)
    add("tiny", tiny_source.resize((64, 48), RESAMPLE), "tiny", ["low_res"], 1)
    return photos


def assets_for(manifest: dict[str, dict]) -> list[dict]:
    """Build Immich-shaped asset fixtures from a corpus manifest.

    ``checksum`` is the base64-encoded SHA-1 of the file, matching Immich's
    AssetResponseDto, not the hex SHA-256 used for corpus integrity.
    """
    base_time = datetime(2024, 1, 1, 12, 0, 0, tzinfo=timezone.utc)
    assets = []
    for index, entry in enumerate(manifest.values()):
        data = Path(entry["path"]).read_bytes()
        checksum = base64.b64encode(hashlib.sha1(data).digest()).decode()
        taken = (base_time + timedelta(minutes=index)).isoformat(timespec="milliseconds")
        taken = taken.replace("+00:00", "Z")
        assets.append(
            {
                "id": f"asset-{entry['id']}",
                "type": "IMAGE",
                "checksum": checksum,
                "width": entry["width"],
                "height": entry["height"],
                "localDateTime": taken,
                "fileCreatedAt": taken,
                "fileModifiedAt": taken,
                "createdAt": taken,
                "updatedAt": taken,
                "originalFileName": f"{entry['id']}.jpg",
                "originalPath": f"upload/{entry['id']}.jpg",
                "ownerId": "user-1",
                "thumbhash": None,
                "isFavorite": False,
                "isArchived": False,
                "isTrashed": False,
                "isOffline": False,
                "isEdited": False,
                "hasMetadata": True,
                "duration": None,
                "livePhotoVideoId": None,
                "visibility": "timeline",
                "exifInfo": {
                    "make": "Test",
                    "model": "Test",
                    "exifImageWidth": entry["width"],
                    "exifImageHeight": entry["height"],
                },
                "preview": data,
            }
        )
    return assets
