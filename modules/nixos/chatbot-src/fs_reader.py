"""Read-only filesystem tool server for Open WebUI.

A deliberately reduced derivative of the upstream
`open-webui/openapi-servers` filesystem server: every mutating endpoint
(write/edit/create/move) is removed, so read-only access is enforced by this
process *and* by the systemd `ReadOnlyPaths=` sandbox around it.

Exposed to Open WebUI as an OpenAPI tool server, so the model can list, read
and search files inside the allowlisted roots and nothing else. Confinement
lives in `path_guard` (stdlib-only, unit-tested separately).
"""

from __future__ import annotations

import os
import pathlib
from typing import List, Optional

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

from path_guard import AccessDenied, InvalidPath, normalize_path, parse_allowed

MAX_READ_BYTES = int(os.getenv("MAX_READ_BYTES", "262144"))  # 256 KiB
MAX_TREE_DEPTH = int(os.getenv("MAX_TREE_DEPTH", "3"))
MAX_SEARCH_RESULTS = int(os.getenv("MAX_SEARCH_RESULTS", "200"))

ALLOWED_DIRECTORIES: List[pathlib.Path] = parse_allowed(
    os.getenv("ALLOWED_DIRECTORIES", "")
)

if not ALLOWED_DIRECTORIES:
    raise RuntimeError(
        "ALLOWED_DIRECTORIES is empty; refusing to start with unlimited scope"
    )


def resolve(requested: str) -> pathlib.Path:
    """Confine a requested path, translating guard failures into HTTP errors."""
    try:
        return normalize_path(requested, ALLOWED_DIRECTORIES)
    except InvalidPath as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except AccessDenied as exc:
        raise HTTPException(
            status_code=403,
            detail={
                "error": "Access Denied",
                "requested_path": str(exc.requested),
                "message": "Requested path is outside allowed directories.",
                "allowed_directories": [str(r) for r in exc.allowed],
            },
        ) from exc


class PathRequest(BaseModel):
    path: str = Field(..., description="Absolute path to operate on")


class TreeRequest(BaseModel):
    path: str = Field(..., description="Directory to walk recursively")
    max_depth: int = Field(MAX_TREE_DEPTH, ge=0, le=8)


class SearchRequest(BaseModel):
    path: str = Field(..., description="Directory to search within")
    pattern: str = Field(..., description="Case-insensitive filename substring")
    exclude_patterns: Optional[List[str]] = Field(
        default_factory=list, description="Filename substrings to exclude"
    )


app = FastAPI(
    title="Read-only Filesystem API",
    version="1.0.0",
    description=(
        "Read-only, allowlist-confined filesystem access for Open WebUI. "
        "Mutating operations are intentionally not implemented."
    ),
)


@app.get("/healthz")
async def healthz() -> dict:
    return {"status": "ok"}


@app.get("/allowed_directories")
async def allowed_directories() -> dict:
    return {"allowed_directories": [str(r) for r in ALLOWED_DIRECTORIES]}


@app.post("/files/list")
async def list_directory(req: PathRequest) -> dict:
    target = resolve(req.path)

    if not target.exists():
        raise HTTPException(status_code=404, detail="Path not found")
    if not target.is_dir():
        raise HTTPException(status_code=400, detail="Not a directory")

    entries = []
    for item in sorted(target.iterdir(), key=lambda p: (p.is_file(), p.name.lower())):
        try:
            stat = item.stat()
        except OSError:
            continue
        entries.append(
            {
                "name": item.name,
                "type": (
                    "directory" if item.is_dir() else "symlink" if item.is_symlink() else "file"
                ),
                "size": stat.st_size if item.is_file() else None,
            }
        )

    return {"path": str(target), "entries": entries}


def _walk(root: pathlib.Path, depth: int, max_depth: int) -> dict:
    node = {"name": root.name, "type": "directory", "children": []}
    if depth >= max_depth:
        return node
    try:
        children = sorted(root.iterdir(), key=lambda p: (p.is_file(), p.name.lower()))
    except OSError:
        return node
    for child in children:
        if child.is_dir():
            node["children"].append(_walk(child, depth + 1, max_depth))
        else:
            node["children"].append({"name": child.name, "type": "file"})
    return node


@app.post("/files/tree")
async def directory_tree(req: TreeRequest) -> dict:
    target = resolve(req.path)

    if not target.is_dir():
        raise HTTPException(status_code=400, detail="Not a directory")

    return {"path": str(target), "tree": _walk(target, 0, req.max_depth)}


@app.post("/files/read")
async def read_file(req: PathRequest) -> dict:
    target = resolve(req.path)

    if not target.is_file():
        raise HTTPException(status_code=400, detail="Not a file")

    size = target.stat().st_size
    if size > MAX_READ_BYTES:
        raise HTTPException(
            status_code=413,
            detail=f"File is {size} bytes; read limit is {MAX_READ_BYTES}",
        )

    return {"path": str(target), "content": target.read_text(errors="replace")}


@app.post("/files/search")
async def search_files(req: SearchRequest) -> dict:
    target = resolve(req.path)

    if not target.is_dir():
        raise HTTPException(status_code=400, detail="Not a directory")

    pattern = req.pattern.lower()
    excludes = [p.lower() for p in (req.exclude_patterns or [])]

    matches = []
    for dirpath, dirnames, filenames in os.walk(target):
        dirnames[:] = sorted(d for d in dirnames if not any(e in d.lower() for e in excludes))
        for filename in filenames:
            lowered = filename.lower()
            if pattern not in lowered:
                continue
            if any(e in lowered for e in excludes):
                continue
            matches.append(os.path.join(dirpath, filename))
            if len(matches) >= MAX_SEARCH_RESULTS:
                return {
                    "path": str(target),
                    "truncated": True,
                    "matches": matches,
                }

    return {"path": str(target), "truncated": False, "matches": matches}
