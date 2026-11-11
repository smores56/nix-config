"""A small in-process Immich 3.0.3 API double for the photo-triage tests.

It serves only the routes the pipeline uses, enforces per-route permissions for
each configured key, and records every request. The response shapes follow the
pinned server's DTOs, so a client that passes here has a chance against the real
API. Nothing here touches a real Immich instance.
"""

from __future__ import annotations

import json
import os
import socketserver
import threading
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import parse_qs, urlparse

PUBLIC_PATHS = frozenset({"/api/server/version"})
DEFAULT_TIME = "2024-01-01T00:00:00.000Z"


@dataclass(frozen=True)
class RequestRecord:
    method: str
    path: str
    query: dict[str, list[str]]
    headers: dict[str, str]
    body: bytes


class FakeImmich:
    """Serve the subset of Immich 3.x used by photo-triage.

    ``assets`` entries carry an ``id``, Immich-shaped metadata, and a
    ``preview`` bytes value (or None to simulate a missing thumbnail).
    ``duplicates`` is a list of ``{duplicateId, assetIds, suggestedKeepAssetIds?}``
    groups. ``keys`` maps an API key to its permission list; the default key is
    ``api_key`` with ``permissions``.
    """

    def __init__(
        self,
        assets: list[dict[str, Any]],
        duplicates: list[dict[str, Any]] | None = None,
        stacks: list[dict[str, Any]] | None = None,
        albums: list[dict[str, Any]] | None = None,
        keys: dict[str, list[str]] | None = None,
        api_key: str = "test-key",
        permissions: list[str] | None = None,
        require_auth: bool = True,
        unix_path: str | None = None,
    ) -> None:
        self.api_key = api_key
        self.unix_path = unix_path
        self.keys = (
            {key: list(value) for key, value in keys.items()}
            if keys is not None
            else {api_key: list(permissions or ())}
        )
        self.require_auth = require_auth
        self.assets = {asset["id"]: dict(asset) for asset in assets}
        self.duplicates = [dict(group) for group in (duplicates or ())]
        self.stacks_override = stacks
        self.albums: dict[str, dict[str, Any]] = {}
        for album in albums or ():
            self.albums[album["id"]] = {
                "id": album["id"],
                "albumName": album.get("albumName", ""),
                "description": album.get("description", ""),
                "assetIds": list(album.get("assetIds", [])),
            }
        self.requests: list[RequestRecord] = []
        self.errors: list[str] = []
        self.fail_add_ids: set[str] = set()
        self._failures: list[tuple[int, str | None, str | None]] = []
        self._album_seq = 0
        self._lock = threading.RLock()
        self._server: ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None
        self.base_url = ""

    def __enter__(self) -> "FakeImmich":
        self.start()
        return self

    def __exit__(self, *exc: object) -> None:
        self.stop()

    def start(self) -> str:
        if self._server is not None:
            return self.base_url
        owner = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.0"

            def do_GET(self) -> None:
                owner._handle(self)

            def do_POST(self) -> None:
                owner._handle(self)

            def do_PUT(self) -> None:
                owner._handle(self)

            def do_DELETE(self) -> None:
                owner._handle(self)

            def log_message(self, *args: object) -> None:
                return

        if self.unix_path:
            server = socketserver.ThreadingUnixStreamServer

            class UnixServer(server):
                daemon_threads = True

            self._server = UnixServer(self.unix_path, Handler)
            os.chmod(self.unix_path, 0o600)
            self.base_url = f"unix:{self.unix_path}"
        else:
            self._server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            self._server.daemon_threads = True
            self.base_url = f"http://127.0.0.1:{self._server.server_port}"
        self._thread = threading.Thread(
            target=self._server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True
        )
        self._thread.start()
        return self.base_url

    def stop(self) -> None:
        if self._server is not None:
            self._server.shutdown()
            self._server.server_close()
        if self._thread is not None:
            self._thread.join(timeout=5)
        if self.unix_path:
            try:
                os.unlink(self.unix_path)
            except FileNotFoundError:
                pass
        self._server = None
        self._thread = None
        self.base_url = ""

    def queue_failure(
        self,
        status: int,
        count: int = 1,
        method: str | None = None,
        path_prefix: str | None = None,
    ) -> None:
        with self._lock:
            self._failures.extend([(status, method, path_prefix)] * count)

    def set_fail_add(self, asset_ids: set[str]) -> None:
        with self._lock:
            self.fail_add_ids = set(asset_ids)

    def album_asset_ids(self, album_id: str) -> list[str] | None:
        with self._lock:
            album = self.albums.get(album_id)
            return list(album["assetIds"]) if album else None

    def _permissions(self, key: str | None) -> list[str]:
        return self.keys.get(key or "", [])

    def _permitted(self, key: str | None, permission: str | None) -> bool:
        if not self.require_auth or permission is None:
            return True
        granted = self._permissions(key)
        return "all" in granted or permission in granted

    def _send_forbidden(self, request: BaseHTTPRequestHandler) -> None:
        self._send_json(request, 403, {"message": "Missing required permission"})

    def _take_failure(self, method: str, path: str) -> int | None:
        with self._lock:
            for index, (status, failure_method, prefix) in enumerate(self._failures):
                if (failure_method is None or failure_method == method) and (
                    prefix is None or path.startswith(prefix)
                ):
                    self._failures.pop(index)
                    return status
        return None

    def _public_asset(self, asset: dict[str, Any]) -> dict[str, Any]:
        result = {
            key: value
            for key, value in asset.items()
            if key not in {"preview", "stackId", "stackPrimary"}
        }
        timestamp = result.get("localDateTime", DEFAULT_TIME)
        defaults = {
            "type": "IMAGE",
            "checksum": "",
            "originalFileName": f"{result.get('id', 'asset')}.jpg",
            "originalPath": f"upload/{result.get('id', 'asset')}.jpg",
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
            "createdAt": timestamp,
            "fileCreatedAt": timestamp,
            "fileModifiedAt": timestamp,
            "updatedAt": timestamp,
        }
        for key, value in defaults.items():
            result.setdefault(key, value)
        return result

    def _album_dto(self, album: dict[str, Any]) -> dict[str, Any]:
        return {
            "id": album["id"],
            "albumName": album["albumName"],
            "description": album.get("description", ""),
            "albumThumbnailAssetId": None,
            "albumUsers": [],
            "shared": False,
            "hasSharedLink": False,
            "startDate": None,
            "endDate": None,
            "assetCount": len(album["assetIds"]),
            "isActivityEnabled": True,
            "order": "desc",
            "createdAt": DEFAULT_TIME,
            "updatedAt": DEFAULT_TIME,
        }

    def _handle(self, request: BaseHTTPRequestHandler) -> None:
        parsed = urlparse(request.path)
        path = parsed.path
        query = parse_qs(parsed.query)
        length = int(request.headers.get("Content-Length", "0") or 0)
        body = request.rfile.read(length) if length else b""
        key = request.headers.get("X-Api-Key") or (query.get("key") or [None])[0]
        with self._lock:
            self.requests.append(
                RequestRecord(request.command, path, query, dict(request.headers.items()), body)
            )
        if self.require_auth and path not in PUBLIC_PATHS and key not in self.keys:
            self._send_json(request, 401, {"message": "Unauthorized"})
            return
        failure = self._take_failure(request.command, path)
        if failure is not None:
            self._send_json(request, failure, {"message": "injected failure"})
            return
        try:
            if request.command == "GET":
                self._get(request, path, query, key)
            elif request.command == "POST":
                self._post(request, path, body, key)
            elif request.command == "PUT":
                self._put(request, path, body, key)
            elif request.command == "DELETE":
                self._delete(request, path, body, key)
            else:
                self._send_json(request, 405, {"message": "Method Not Allowed"})
        except Exception as exc:  # noqa: BLE001 - a test double must answer, not die
            with self._lock:
                self.errors.append(f"{request.command} {path}: {exc!r}")
            self._send_json(request, 500, {"message": "Internal Server Error"})

    def _get(
        self,
        request: BaseHTTPRequestHandler,
        path: str,
        query: dict[str, list[str]],
        key: str | None,
    ) -> None:
        if path == "/api/server/version":
            self._send_json(request, 200, {"major": 3, "minor": 0, "patch": 3})
            return
        if path == "/api/server/about":
            if not self._permitted(key, "server.about"):
                self._send_forbidden(request)
                return
            self._send_json(
                request,
                200,
                {"version": "3.0.3", "licensed": True, "versionUrl": "https://example.invalid"},
            )
            return
        if path == "/api/api-keys/me":
            self._send_json(
                request,
                200,
                {"id": "key-1", "name": "test", "permissions": self._permissions(key)},
            )
            return
        if path.startswith("/api/assets/"):
            parts = path.split("/")
            if len(parts) >= 5 and parts[4] == "thumbnail":
                if not self._permitted(key, "asset.view"):
                    self._send_forbidden(request)
                    return
                asset = self.assets.get(parts[3])
                if asset is None or asset.get("preview") is None:
                    self._send_json(request, 404, {"message": "Not found"})
                    return
                self._send_bytes(request, 200, asset["preview"], "image/jpeg")
                return
            if len(parts) >= 5 and parts[4] == "original":
                if not self._permitted(key, "asset.download"):
                    self._send_forbidden(request)
                    return
                asset = self.assets.get(parts[3])
                if asset is None or asset.get("preview") is None:
                    self._send_json(request, 404, {"message": "Not found"})
                    return
                self._send_bytes(request, 200, asset["preview"], "image/jpeg")
                return
            if len(parts) == 4:
                if not self._permitted(key, "asset.read"):
                    self._send_forbidden(request)
                    return
                asset = self.assets.get(parts[3])
                if asset is None:
                    self._send_json(request, 404, {"message": "Not found"})
                    return
                self._send_json(request, 200, self._public_asset(asset))
                return
        if path == "/api/duplicates":
            if not self._permitted(key, "duplicate.read"):
                self._send_forbidden(request)
                return
            groups = []
            with self._lock:
                for group in self.duplicates:
                    groups.append(
                        {
                            "duplicateId": group["duplicateId"],
                            "assets": [
                                self._public_asset(self.assets[asset_id])
                                for asset_id in group["assetIds"]
                                if asset_id in self.assets
                            ],
                            "suggestedKeepAssetIds": list(group.get("suggestedKeepAssetIds", [])),
                        }
                    )
            self._send_json(request, 200, groups)
            return
        if path == "/api/stacks":
            if not self._permitted(key, "stack.read"):
                self._send_forbidden(request)
                return
            if self.stacks_override is not None:
                self._send_json(request, 200, self.stacks_override)
                return
            grouped: dict[str, list[dict[str, Any]]] = {}
            with self._lock:
                for asset in self.assets.values():
                    stack_id = asset.get("stackId")
                    if not stack_id or asset.get("isTrashed"):
                        continue
                    # Immich returns archive and timeline members, not hidden/locked.
                    if asset.get("visibility") in ("hidden", "locked"):
                        continue
                    grouped.setdefault(str(stack_id), []).append(asset)
            payload = []
            for stack_id in sorted(grouped):
                members = sorted(grouped[stack_id], key=lambda item: str(item["id"]))
                primary = next(
                    (str(item["id"]) for item in members if item.get("stackPrimary")),
                    str(members[0]["id"]),
                )
                payload.append(
                    {
                        "id": stack_id,
                        "primaryAssetId": primary,
                        "assets": [self._public_asset(item) for item in members],
                    }
                )
            self._send_json(request, 200, payload)
            return
        if path == "/api/albums":
            if not self._permitted(key, "album.read"):
                self._send_forbidden(request)
                return
            with self._lock:
                albums = [self._album_dto(album) for album in self.albums.values()]
            self._send_json(request, 200, albums)
            return
        if path.startswith("/api/albums/"):
            if not self._permitted(key, "album.read"):
                self._send_forbidden(request)
                return
            album_id = path.split("/")[3]
            with self._lock:
                album = self.albums.get(album_id)
                if album is None:
                    self._send_json(request, 400, {"message": "Album not found"})
                    return
                payload = self._album_dto(album)
            self._send_json(request, 200, payload)
            return
        self._send_json(request, 404, {"message": "Not found"})

    def _post(
        self, request: BaseHTTPRequestHandler, path: str, body: bytes, key: str | None
    ) -> None:
        data = self._json(body)
        if data is None:
            self._send_json(request, 400, {"message": "Invalid JSON"})
            return
        if path == "/api/search/metadata":
            if not self._permitted(key, "asset.read"):
                self._send_forbidden(request)
                return
            page = data.get("page", 1)
            size = data.get("size", 250)
            if not isinstance(page, int) or page < 1 or not isinstance(size, int) or size < 1:
                self._send_json(request, 400, {"message": "Invalid pagination"})
                return
            with self._lock:
                candidates = self._visible(data)
                items = [self._public_asset(asset) for asset in candidates]
            start = (page - 1) * size
            page_items = items[start : start + size]
            next_page = str(page + 1) if start + size < len(items) else None
            # 3.0.3 mapResponse sets total to the page length, not the library size.
            self._send_json(
                request,
                200,
                {
                    "albums": {"total": 0, "count": 0, "items": [], "facets": []},
                    "assets": {
                        "total": len(page_items),
                        "count": len(page_items),
                        "items": page_items,
                        "facets": [],
                        "nextPage": next_page,
                    },
                },
            )
            return
        if path == "/api/albums":
            if not self._permitted(key, "album.create"):
                self._send_forbidden(request)
                return
            name = data.get("albumName")
            if not isinstance(name, str) or not name:
                self._send_json(request, 400, {"message": "albumName is required"})
                return
            with self._lock:
                self._album_seq += 1
                album_id = f"album-{self._album_seq}"
                asset_ids = [asset_id for asset_id in data.get("assetIds", []) if asset_id in self.assets]
                self.albums[album_id] = {
                    "id": album_id,
                    "albumName": name,
                    "description": data.get("description", ""),
                    "assetIds": asset_ids,
                }
                payload = self._album_dto(self.albums[album_id])
            self._send_json(request, 201, payload)
            return
        self._send_json(request, 404, {"message": "Not found"})

    def _visible(self, data: dict[str, Any]) -> list[dict[str, Any]]:
        with_deleted = bool(data.get("withDeleted", False))
        requested_type = data.get("type")
        requested_visibility = data.get("visibility")
        with_stacked = data.get("withStacked")
        created_before = data.get("createdBefore")
        assets = []
        for asset in self.assets.values():
            if not with_deleted and asset.get("isTrashed"):
                continue
            if requested_type and asset.get("type") != requested_type:
                continue
            if requested_visibility and asset.get("visibility", "timeline") != requested_visibility:
                continue
            # Immich 3.x compiles withStacked=false to `asset.stackId IS NULL`,
            # which also drops stack primaries.
            if with_stacked is False and asset.get("stackId") is not None:
                continue
            if asset.get("visibility") == "locked":
                continue
            if created_before and asset.get("createdAt", "") >= created_before:
                continue
            assets.append(asset)
        return sorted(assets, key=lambda asset: (asset.get("localDateTime", ""), asset["id"]))

    def _put(self, request: BaseHTTPRequestHandler, path: str, body: bytes, key: str | None) -> None:
        data = self._json(body)
        if data is None:
            self._send_json(request, 400, {"message": "Invalid JSON"})
            return
        if path.startswith("/api/albums/") and path.endswith("/assets"):
            if not self._permitted(key, "albumAsset.create"):
                self._send_forbidden(request)
                return
            album_id = path.split("/")[3]
            with self._lock:
                album = self.albums.get(album_id)
                if album is None:
                    self._send_json(request, 400, {"message": "Not found or no access"})
                    return
                results = []
                for asset_id in data.get("ids", []):
                    if asset_id not in self.assets or asset_id in self.fail_add_ids:
                        results.append(
                            {
                                "id": asset_id,
                                "success": False,
                                "error": "no_permission",
                                "errorMessage": "No access to asset",
                            }
                        )
                    elif asset_id in album["assetIds"]:
                        results.append(
                            {"id": asset_id, "success": False, "error": "duplicate"}
                        )
                    else:
                        album["assetIds"].append(asset_id)
                        results.append({"id": asset_id, "success": True})
            self._send_json(request, 200, results)
            return
        self._send_json(request, 404, {"message": "Not found"})

    def _delete(
        self, request: BaseHTTPRequestHandler, path: str, body: bytes, key: str | None
    ) -> None:
        data = self._json(body)
        if data is None:
            self._send_json(request, 400, {"message": "Invalid JSON"})
            return
        if path.startswith("/api/albums/") and path.endswith("/assets"):
            if not self._permitted(key, "albumAsset.delete"):
                self._send_forbidden(request)
                return
            album_id = path.split("/")[3]
            with self._lock:
                album = self.albums.get(album_id)
                if album is None:
                    self._send_json(request, 400, {"message": "Not found or no access"})
                    return
                results = []
                for asset_id in data.get("ids", []):
                    if asset_id in album["assetIds"]:
                        album["assetIds"].remove(asset_id)
                        results.append({"id": asset_id, "success": True})
                    else:
                        results.append(
                            {"id": asset_id, "success": False, "error": "not_found"}
                        )
            self._send_json(request, 200, results)
            return
        self._send_json(request, 404, {"message": "Not found"})

    @staticmethod
    def _json(body: bytes) -> dict[str, Any] | None:
        try:
            return json.loads(body.decode("utf-8")) if body else None
        except (UnicodeDecodeError, json.JSONDecodeError):
            return None

    def _send_json(
        self, request: BaseHTTPRequestHandler, status: int, payload: dict[str, Any] | list
    ) -> None:
        self._send_bytes(request, status, json.dumps(payload).encode("utf-8"), "application/json")

    @staticmethod
    def _send_bytes(
        request: BaseHTTPRequestHandler, status: int, payload: bytes, content_type: str
    ) -> None:
        request.send_response(status)
        request.send_header("Content-Type", content_type)
        request.send_header("Content-Length", str(len(payload)))
        request.end_headers()
        request.wfile.write(payload)
