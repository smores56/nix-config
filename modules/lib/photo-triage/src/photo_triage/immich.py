"""Immich 3.0.3 read client over the Immich Unix-socket relay.

The scorer never opens an IP socket: it connects to the relay's Unix socket and
speaks HTTP there. The exact read-key permissions are asserted at scan start.
"""

from __future__ import annotations

import http.client
import json
from typing import Any
from urllib.parse import quote

from .transport import UnixHTTPConnection

READ_PERMISSIONS = frozenset(
    {"asset.read", "asset.view", "album.read", "duplicate.read", "stack.read"}
)
ALBUM_PERMISSIONS = frozenset(
    {"album.read", "album.create", "albumAsset.create", "albumAsset.delete"}
)
TRANSIENT_STATUS = frozenset({408, 429, 500, 502, 503, 504})


class ImmichError(Exception):
    def __init__(self, status: int, message: str, *, transient: bool) -> None:
        super().__init__(f"Immich {status}: {message}")
        self.status = status
        self.message = message
        self.transient = transient


class ImmichPermissionError(ImmichError):
    pass


class ImmichClient:
    def __init__(self, *, api_key: str, socket_path: str, timeout: float = 30) -> None:
        self.api_key = api_key
        self.socket_path = socket_path
        self.timeout = timeout

    def _connection(self) -> http.client.HTTPConnection:
        return UnixHTTPConnection(self.socket_path, timeout=self.timeout)

    def _request(
        self,
        method: str,
        path: str,
        *,
        body: bytes | None = None,
        headers: dict[str, str] | None = None,
    ) -> bytes:
        request_headers = {"X-Api-Key": self.api_key, "Accept": "application/json"}
        if body is not None:
            request_headers["Content-Type"] = "application/json"
        request_headers.update(headers or {})
        connection = self._connection()
        try:
            connection.request(method, path, body=body, headers=request_headers)
            response = connection.getresponse()
            data = response.read()
            status = response.status
        except (OSError, http.client.HTTPException) as error:
            raise ImmichError(0, str(error), transient=True) from error
        finally:
            connection.close()
        if status >= 400:
            raise ImmichError(
                status,
                self._message(data),
                transient=status in TRANSIENT_STATUS,
            )
        return data

    @staticmethod
    def _message(data: bytes) -> str:
        try:
            payload = json.loads(data)
            if isinstance(payload, dict) and "message" in payload:
                return str(payload["message"])
        except (UnicodeDecodeError, json.JSONDecodeError):
            pass
        return data.decode("utf-8", "replace")[:200]

    def _json(self, method: str, path: str, **kwargs: Any) -> Any:
        data = self._request(method, path, **kwargs)
        try:
            return json.loads(data)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ImmichError(0, "response is not JSON", transient=False) from error

    def version(self) -> tuple[int, int, int]:
        payload = self._json("GET", "/api/server/version")
        try:
            return (int(payload["major"]), int(payload["minor"]), int(payload["patch"]))
        except (KeyError, TypeError, ValueError) as error:
            raise ImmichError(0, "unexpected version payload", transient=False) from error

    def permissions(self) -> list[str]:
        payload = self._json("GET", "/api/api-keys/me")
        permissions = payload.get("permissions", []) if isinstance(payload, dict) else []
        if not isinstance(permissions, list):
            raise ImmichError(0, "unexpected API key payload", transient=False)
        return list(permissions)

    def assert_read_permissions(self) -> None:
        granted = set(self.permissions())
        if granted != READ_PERMISSIONS:
            missing = sorted(READ_PERMISSIONS - granted)
            extra = sorted(granted - READ_PERMISSIONS)
            raise ImmichPermissionError(
                403,
                f"read key permissions mismatch; missing={missing} extra={extra}",
                transient=False,
            )

    def search_metadata(self, page: int = 1, size: int = 250, **filters: Any) -> dict[str, Any]:
        page = max(int(page), 1)
        size = max(1, min(int(size), 1000))
        body = json.dumps({"page": page, "size": size, **filters}).encode("utf-8")
        payload = self._json("POST", "/api/search/metadata", body=body)
        if not isinstance(payload, dict) or not isinstance(payload.get("assets"), dict):
            raise ImmichError(0, "unexpected search payload", transient=False)
        assets = payload["assets"]
        items = assets.get("items")
        if not isinstance(items, list):
            raise ImmichError(0, "search payload has no items list", transient=False)
        return {
            "items": items,
            "nextPage": assets.get("nextPage"),
            "count": assets.get("count", len(items)),
            "total": assets.get("total", len(items)),
        }

    def asset(self, asset_id: str) -> dict[str, Any]:
        return self._json("GET", f"/api/assets/{quote(asset_id, safe='')}")

    def thumbnail(self, asset_id: str, size: str = "preview") -> bytes:
        return self._request(
            "GET",
            f"/api/assets/{quote(asset_id, safe='')}/thumbnail?size={quote(size, safe='')}",
        )

    def duplicates(self) -> list[dict[str, Any]]:
        payload = self._json("GET", "/api/duplicates")
        if not isinstance(payload, list):
            raise ImmichError(0, "duplicates response is not a list", transient=False)
        return payload

    def stacks(self) -> list[dict[str, Any]]:
        payload = self._json("GET", "/api/stacks")
        if not isinstance(payload, list):
            raise ImmichError(0, "stacks response is not a list", transient=False)
        return payload

    def assert_album_permissions(self) -> None:
        granted = set(self.permissions())
        if granted != ALBUM_PERMISSIONS:
            missing = sorted(ALBUM_PERMISSIONS - granted)
            extra = sorted(granted - ALBUM_PERMISSIONS)
            raise ImmichPermissionError(
                403,
                f"album key permissions mismatch; missing={missing} extra={extra}",
                transient=False,
            )

    def albums(self, name: str | None = None) -> list[dict[str, Any]]:
        path = "/api/albums"
        if name is not None:
            path += f"?name={quote(name, safe='')}"
        payload = self._json("GET", path)
        if not isinstance(payload, list):
            raise ImmichError(0, "albums response is not a list", transient=False)
        # The server filters by name; filter again so a proxy or older server
        # cannot hand us an unrelated album.
        albums = [album for album in payload if isinstance(album, dict)]
        if name is not None:
            albums = [album for album in albums if album.get("albumName") == name]
        return albums

    def album(self, album_id: str) -> dict[str, Any]:
        payload = self._json("GET", f"/api/albums/{quote(album_id, safe='')}")
        if not isinstance(payload, dict) or not payload.get("id"):
            raise ImmichError(0, "unexpected album payload", transient=False)
        return payload

    def create_album(self, name: str) -> dict[str, Any]:
        body = json.dumps({"albumName": name}).encode("utf-8")
        payload = self._json("POST", "/api/albums", body=body)
        if not isinstance(payload, dict) or not payload.get("id"):
            raise ImmichError(0, "unexpected album payload", transient=False)
        return payload

    def add_album_assets(self, album_id: str, asset_ids: list[str]) -> list[dict[str, Any]]:
        body = json.dumps({"ids": asset_ids}).encode("utf-8")
        payload = self._json(
            "PUT", f"/api/albums/{quote(album_id, safe='')}/assets", body=body
        )
        return self._bulk_response(payload)

    def remove_album_assets(self, album_id: str, asset_ids: list[str]) -> list[dict[str, Any]]:
        body = json.dumps({"ids": asset_ids}).encode("utf-8")
        payload = self._json(
            "DELETE", f"/api/albums/{quote(album_id, safe='')}/assets", body=body
        )
        return self._bulk_response(payload)

    @staticmethod
    def _bulk_response(payload: Any) -> list[dict[str, Any]]:
        if not isinstance(payload, list) or not all(
            isinstance(item, dict) and "id" in item for item in payload
        ):
            raise ImmichError(0, "unexpected bulk response", transient=False)
        return payload
