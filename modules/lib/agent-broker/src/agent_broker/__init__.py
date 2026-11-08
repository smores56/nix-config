"""Credential-injecting capability broker for the agent VM (sdlc #459).

The broker is the only place a mediated credential exists. It replaces the caller's
Authorization/API-key header with the declared one and forwards a fixed upstream, so the
guest can use the capability but never read the secret.
"""

from __future__ import annotations

import base64
import json
import os
from dataclasses import dataclass
from pathlib import Path

# Connection-scoped headers terminate at each hop and are never forwarded.
HOP_BY_HOP = frozenset(
    {
        "connection",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "te",
        "trailer",
        "trailers",
        "transfer-encoding",
        "upgrade",
        "host",
        "content-length",
    }
)


@dataclass(frozen=True)
class Auth:
    kind: str  # bearer, header, basic, none
    header: str
    username: str
    credential: str


@dataclass(frozen=True)
class Config:
    listen: str
    upstream: str
    allow: tuple[str, ...]
    auth: Auth

    @property
    def host(self) -> str:
        return self.listen.rsplit(":", 1)[0]

    @property
    def port(self) -> int:
        return int(self.listen.rsplit(":", 1)[1])


def load_config(path: str | Path) -> Config:
    raw = json.loads(Path(path).read_text())
    auth = raw.get("auth") or {}
    config = Config(
        listen=raw["listen"],
        upstream=raw["upstream"].rstrip("/"),
        allow=tuple(raw.get("allow") or ()),
        auth=Auth(
            kind=auth.get("kind", "none"),
            header=auth.get("header", ""),
            username=auth.get("username", ""),
            credential=auth.get("credential", ""),
        ),
    )
    if ":" not in config.listen:
        raise ValueError(f"listen must be host:port, got {config.listen!r}")
    if config.auth.kind not in ("bearer", "header", "basic", "none"):
        raise ValueError(f"unknown auth kind {config.auth.kind!r}")
    if config.auth.kind == "header" and not config.auth.header:
        raise ValueError("header auth needs a header name")
    if config.auth.kind != "none" and not config.auth.credential:
        raise ValueError("an auth kind needs a credential")
    if not config.upstream.startswith(("http://", "https://")):
        raise ValueError(f"upstream must be an absolute http(s) URL, got {config.upstream!r}")
    return config


def read_credential(name: str) -> str:
    directory = os.environ.get("CREDENTIALS_DIRECTORY")
    if not directory:
        raise RuntimeError("CREDENTIALS_DIRECTORY is not set; the unit must LoadCredential")
    return Path(directory, name).read_text().strip()


def allowed(rules: tuple[str, ...], method: str, path: str) -> bool:
    """Match "METHOD /path" rules; a trailing * is a prefix, and no rules allow everything."""
    if not rules:
        return True
    for rule in rules:
        rule_method, _, rule_path = rule.partition(" ")
        if rule_method and rule_method != method:
            continue
        if rule_path.endswith("*"):
            if path.startswith(rule_path[:-1]):
                return True
        elif path == rule_path:
            return True
    return False


def build_headers(headers: dict[str, str], auth: Auth, key: str) -> dict[str, str]:
    """Copy caller headers minus hop-by-hop and any credential, then set the declared one."""
    drop = HOP_BY_HOP | {"authorization"}
    if auth.header:
        drop = drop | {auth.header.lower()}
    out = {k: v for k, v in headers.items() if k.lower() not in drop}
    if auth.kind == "bearer":
        out["Authorization"] = f"Bearer {key}"
    elif auth.kind == "header":
        out[auth.header] = key
    elif auth.kind == "basic":
        token = base64.b64encode(f"{auth.username}:{key}".encode()).decode()
        out["Authorization"] = f"Basic {token}"
    return out
