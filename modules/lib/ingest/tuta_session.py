"""Stage the TutaBridge session inside the `ingest-tuta` guest.

The bridge keeps its Tuta login in `pass` (encrypted with a dedicated GPG key)
and its settings in `config.toml`. Firecracker gives the guest one read-only
secret block device and no writable disk that survives a reboot, so the whole
session — `gnupg/`, `pass/` and `config/tutabridge/config.toml` from a one-time
`tutabridge init` — is carried as one base64 tar.gz value in that device's
`env` file:

    TUTA_ADDRESS=owner@tuta.com
    TUTA_SESSION_B64=<base64 of the session tar.gz>
    TUTA_BRIDGE_PASSWORD=<bridge password, optional: config.toml may carry it>
    TUTA_PASS_PATH=tuta/bridge          # optional, the pass entry prefix
    TUTA_TOTP_SECRET=...                # optional, for the next one-time login

Parsing and archive extraction are pure so the unit tests cover the traversal
and schema refusals without a Tuta account. Extraction refuses absolute paths,
`..`, links and anything outside the three expected prefixes; the result lands
under `/var/lib/tutabridge` (tmpfs in the guest) at 0700 and never in a log.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import io
import json
import os
import re
import sys
import tarfile
from dataclasses import dataclass

ALLOWED_KEYS = {
    "TUTA_ADDRESS",
    "TUTA_SESSION_B64",
    "TUTA_BRIDGE_PASSWORD",
    "TUTA_PASS_PATH",
    "TUTA_TOTP_SECRET",
}
REQUIRED_KEYS = {"TUTA_ADDRESS"}
# The session is a GPG keyring plus one pass entry. The base64 form has to fit
# the 4 MiB secret image's `/env`, so the decoded cap stays at 2 MiB.
MAX_SESSION_BYTES = 2 * 1024 * 1024
ARCHIVE_PREFIXES = ("gnupg/", "pass/", "config/")
DEFAULT_PASS_PATH = "tuta/bridge"
ADDRESS_RE = re.compile(r"^[^@\s]{1,64}@[A-Za-z0-9.-]{1,253}$")
KEY_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")
BRIDGE_PASSWORD_RE = re.compile(r'^bridge_password\s*=\s*"([^"]*)"\s*$', re.MULTILINE)


class SessionError(ValueError):
    """An env file, archive or config the staging unit refuses."""


@dataclass(frozen=True)
class Session:
    address: str
    pass_path: str
    bridge_password: str | None
    totp_secret: str | None
    archive: bytes | None


def parse_env(text: str) -> dict[str, str]:
    """Parse the `KEY=value` contract strictly: no export, no interpolation, no duplicates."""
    if not isinstance(text, str):
        raise SessionError("env is not text")
    values: dict[str, str] = {}
    for number, raw in enumerate(text.splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise SessionError(f"line {number}: not KEY=value")
        key, _, value = line.partition("=")
        key = key.strip()
        if not KEY_RE.match(key):
            raise SessionError(f"line {number}: key {key!r} is not uppercase")
        if key in values:
            raise SessionError(f"line {number}: duplicate key {key}")
        value = value.strip()
        if (value.startswith('"') and value.endswith('"')) or (
            value.startswith("'") and value.endswith("'")
        ):
            value = value[1:-1]
        values[key] = value
    return values


def parse_env_file(path: str) -> dict[str, str]:
    try:
        with open(path, encoding="utf-8") as handle:
            return parse_env(handle.read())
    except FileNotFoundError as exc:
        raise SessionError(f"missing {path}; stage the ingest-tuta secret") from exc


def decode_archive(value: str | None) -> bytes | None:
    if not value:
        return None
    if len(value) > MAX_SESSION_BYTES * 2:
        raise SessionError("session archive is over the size cap")
    try:
        data = base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise SessionError("session archive is not base64") from exc
    if not data:
        raise SessionError("session archive is empty")
    if len(data) > MAX_SESSION_BYTES:
        raise SessionError("session archive is over the size cap")
    return data


def session_of(env: dict[str, str]) -> Session:
    unknown = set(env) - ALLOWED_KEYS
    if unknown:
        raise SessionError(f"unknown keys: {sorted(unknown)}")
    missing = REQUIRED_KEYS - set(env)
    if missing:
        raise SessionError(f"missing keys: {sorted(missing)}")
    address = env["TUTA_ADDRESS"].strip()
    if not ADDRESS_RE.match(address):
        raise SessionError("TUTA_ADDRESS is not an email address")
    pass_path = (env.get("TUTA_PASS_PATH") or DEFAULT_PASS_PATH).strip()
    if not pass_path or pass_path.startswith("/") or ".." in pass_path.split("/"):
        raise SessionError("TUTA_PASS_PATH must be a relative pass name")
    archive = decode_archive(env.get("TUTA_SESSION_B64"))
    return Session(
        address=address,
        pass_path=pass_path,
        bridge_password=env.get("TUTA_BRIDGE_PASSWORD") or None,
        totp_secret=env.get("TUTA_TOTP_SECRET") or None,
        archive=archive,
    )


def safe_extract(archive: bytes, dest: str) -> list[str]:
    """Extract only regular files under gnupg/, pass/ and config/; return their names."""
    written: list[str] = []
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as tar:
        for member in tar.getmembers():
            name = member.name
            if member.isdir():
                continue
            if not member.isfile():
                raise SessionError(f"archive member {name} is not a regular file")
            if name.startswith("/") or ".." in name.split("/"):
                raise SessionError(f"archive member {name} escapes the destination")
            if not name.startswith(ARCHIVE_PREFIXES):
                raise SessionError(f"archive member {name} is outside the session prefixes")
            target = os.path.join(dest, name)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            source = tar.extractfile(member)
            if source is None:
                raise SessionError(f"archive member {name} has no content")
            with open(target, "wb") as handle:
                handle.write(source.read())
            os.chmod(target, 0o600)
            written.append(name)
    return written


def render_config(
    session: Session,
    password: str,
    *,
    imap_port: int,
    smtp_port: int,
    sync_limit: int,
) -> str:
    """Render the bridge's config.toml; loopback-only, sessions read from `pass`."""
    lines = [
        f'email = "{session.address}"',
        f"imap_port = {imap_port}",
        f"smtp_port = {smtp_port}",
        # SMTP must never be reachable from the tap; the poller and bridge share loopback.
        'bind_addr = "127.0.0.1"',
        f'pass_path = "{session.pass_path}"',
        'mcp_permission = "disabled"',
        f"sync_limit = {sync_limit}",
    ]
    lines.append(f'bridge_password = "{password}"')
    return "\n".join(lines) + "\n"


def bridge_password(session: Session, config_text: str) -> str:
    if session.bridge_password:
        return session.bridge_password
    match = BRIDGE_PASSWORD_RE.search(config_text)
    if not match or not match.group(1):
        raise SessionError(
            "no bridge password: set TUTA_BRIDGE_PASSWORD or keep it in the staged config.toml"
        )
    return match.group(1)


def write_private(path: str, data: str) -> None:
    directory = os.path.dirname(path)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    temporary = path + ".tmp"
    with open(temporary, "w", encoding="utf-8") as handle:
        handle.write(data)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)


def stage(
    env: dict[str, str],
    *,
    root: str,
    runtime_dir: str,
    imap_port: int,
    smtp_port: int,
    sync_limit: int,
) -> dict[str, object]:
    """Materialise the session, config and loopback credentials under `root`."""
    session = session_of(env)
    if session.archive is None:
        raise SessionError("no TUTA_SESSION_B64: run the one-time tutabridge init and stage the session")
    os.makedirs(root, mode=0o700, exist_ok=True)
    written = safe_extract(session.archive, root)
    config_path = os.path.join(root, "config", "tutabridge", "config.toml")
    config_text = ""
    if os.path.exists(config_path):
        with open(config_path, encoding="utf-8") as handle:
            config_text = handle.read()
    password = bridge_password(session, config_text)
    write_private(
        config_path,
        render_config(session, password, imap_port=imap_port, smtp_port=smtp_port, sync_limit=sync_limit),
    )
    write_private(os.path.join(runtime_dir, "address"), session.address + "\n")
    write_private(os.path.join(runtime_dir, "bridge-password"), password + "\n")
    return {
        "address": session.address,
        "pass_path": session.pass_path,
        "files": len(written),
        "totp": bool(session.totp_secret),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="tuta-session")
    parser.add_argument("--env", default="/run/ingest-secret/env")
    parser.add_argument("--root", default="/var/lib/tutabridge")
    parser.add_argument("--runtime-dir", default="/run/tutabridge")
    parser.add_argument("--imap-port", type=int, default=1143)
    parser.add_argument("--smtp-port", type=int, default=1025)
    parser.add_argument("--sync-limit", type=int, default=50)
    parser.add_argument("--check", action="store_true", help="validate the env and exit without writing")
    args = parser.parse_args(argv)

    try:
        env = parse_env_file(args.env)
        if args.check:
            session_of(env)
            print(json.dumps({"ok": True, "keys": sorted(env)}, sort_keys=True))
            return 0
        result = stage(
            env,
            root=args.root,
            runtime_dir=args.runtime_dir,
            imap_port=args.imap_port,
            smtp_port=args.smtp_port,
            sync_limit=args.sync_limit,
        )
    except SessionError as exc:
        # Never echo the env: the message names keys, not values.
        print(json.dumps({"event": "error", "reason": str(exc)}, sort_keys=True), flush=True)
        return 65
    print(json.dumps({"event": "staged", **result}, sort_keys=True), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
