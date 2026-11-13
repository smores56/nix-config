"""Brave Sync profile seeding for the `ingest-brave` guest (smores56/sdlc#591).

Brave has no CLI to join a Sync chain. The reliable unattended path is to plant
the OSCrypt blob that `Preferences` keeps at `brave_sync_v2.seed` and run every
Brave instance with `--password-store=basic`, so the fixed "peanuts" key
decrypts the seed. Brave stores it as base64 of the raw blob (`v10` + IV +
ciphertext); the contract carries the same blob as the `v10<base64>` string the
rest of the tools speak, and this module converts. The seed comes from one human
join: either the owner exports it from a workstation profile, or the guest's
`brave-sync-join` unit runs Brave headful under Xvfb and the code is typed with
`xdotool` (documented in `docs/kanbei-ingest-brave.md`).

This tool never prints the seed or the 25-word code. The code, when the join
path uses it, is written to a `0600` runtime file for `xdotool` only.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import json
import os
import re
import sys
import tempfile
from datetime import datetime, timezone

SEED_PATH = ("brave_sync_v2", "seed")
# Only `status` reads the legacy location, so an older profile still reports.
LEGACY_SEED_PATH = ("brave_sync", "v2", "seed")
ENV_KEYS = {"BRAVE_SYNC_SEED", "BRAVE_SYNC_CODE"}
MAX_SEED_BYTES = 65536
MAX_CODE_BYTES = 4096
_SECRETS: set[str] = set()


class SyncError(RuntimeError):
    """A refused secret, Preferences file or seed value."""


def log(event: str, **fields: object) -> None:
    record = {"ts": datetime.now(timezone.utc).isoformat(timespec="seconds"), "unit": "ingest-brave-sync", "event": event}
    record.update(fields)
    print(redact_text(json.dumps(record, sort_keys=True)), flush=True)


def register_secrets(*values: str) -> None:
    for value in values:
        if value:
            _SECRETS.add(value)


def redact_text(text: str) -> str:
    out = str(text)
    for secret in sorted(_SECRETS, key=len, reverse=True):
        out = out.replace(secret, "[redacted]")
    return out


def parse_env(text: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        key, sep, value = line.partition("=")
        if not sep or not re.fullmatch(r"[A-Z][A-Z0-9_]*", key):
            raise SyncError(f"secret line {number} is not a contract KEY=value")
        if key not in ENV_KEYS:
            raise SyncError(f"unknown secret key {key}")
        if key in values:
            raise SyncError(f"secret key {key} appears twice")
        if value[:1] == value[-1:] and value[:1] in ("'", '"') and len(value) >= 2:
            value = value[1:-1]
        values[key] = value
    return values


def validate_seed(value: object) -> str:
    seed = value if isinstance(value, str) else ""
    if seed.startswith('"') and not seed.endswith('"'):
        raise SyncError("BRAVE_SYNC_SEED is an unterminated JSON string")
    if seed[:1] == '"' and seed[-1:] == '"':
        try:
            seed = json.loads(seed)
        except json.JSONDecodeError:
            raise SyncError("BRAVE_SYNC_SEED is not a JSON string") from None
    if not isinstance(seed, str) or not seed:
        raise SyncError("BRAVE_SYNC_SEED is empty")
    if "\n" in seed or "\r" in seed:
        raise SyncError("BRAVE_SYNC_SEED contains a newline")
    if len(seed.encode("utf-8")) > MAX_SEED_BYTES:
        raise SyncError("BRAVE_SYNC_SEED exceeds the size cap")
    return seed


def load_preferences(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as handle:
            prefs = json.load(handle)
    except FileNotFoundError:
        return {}
    except (json.JSONDecodeError, UnicodeDecodeError):
        raise SyncError(f"Preferences file {path} is not JSON") from None
    if not isinstance(prefs, dict):
        raise SyncError(f"Preferences file {path} is not an object")
    return prefs


def write_preferences(path: str, prefs: dict) -> None:
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".Preferences-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(prefs, handle, sort_keys=True)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def value_at(prefs: dict, path: tuple[str, ...]) -> object:
    node: object = prefs
    for part in path:
        if not isinstance(node, dict):
            return None
        node = node.get(part)
    return node


def seed_of(prefs: dict) -> object:
    return value_at(prefs, SEED_PATH)


def stored_seed_value(seed: str) -> str:
    """Encode the contract's `v10<base64>` blob the way Brave stores it.

    Brave base64-encodes the raw `v10` + IV + ciphertext bytes; the contract
    keeps the blob as text so it survives a `.env` line and `sops`.
    """
    try:
        raw = b"v10" + base64.b64decode(seed[3:], validate=True)
    except (binascii.Error, ValueError) as exc:
        raise SyncError(f"BRAVE_SYNC_SEED is not a v10 base64 blob: {exc}") from None
    return base64.b64encode(raw).decode("ascii")


def looks_oscrypt(value: object) -> bool:
    """True for either storage form: the blob string or Brave's base64 of it."""
    if not isinstance(value, str) or not value:
        return False
    if value.startswith("v10"):
        return True
    try:
        return base64.b64decode(value, validate=True)[:3] == b"v10"
    except (binascii.Error, ValueError):
        return False


def plant(prefs: dict, seed: str) -> dict:
    node = prefs
    for part in SEED_PATH[:-1]:
        child = node.get(part)
        if not isinstance(child, dict):
            child = {}
            node[part] = child
        node = child
    node[SEED_PATH[-1]] = stored_seed_value(seed)
    return prefs


def code_of(env: dict[str, str]) -> str | None:
    code = env.get("BRAVE_SYNC_CODE", "").strip()
    if not code:
        return None
    if len(code.encode("utf-8")) > MAX_CODE_BYTES:
        raise SyncError("BRAVE_SYNC_CODE exceeds the size cap")
    return code


def stage(env_path: str, prefs_path: str, code_out: str | None = None) -> dict:
    """Seed Preferences from the secret device; report presence without the value."""
    try:
        with open(env_path, encoding="utf-8") as handle:
            env = parse_env(handle.read())
    except FileNotFoundError:
        return {"seed_present": False, "planted": False, "code_staged": False}
    seed = env.get("BRAVE_SYNC_SEED", "")
    code = code_of(env)
    if seed:
        register_secrets(seed)
    if code:
        register_secrets(code)
    prefs = load_preferences(prefs_path)
    planted = False
    if seed:
        plant(prefs, validate_seed(seed))
        write_preferences(prefs_path, prefs)
        planted = True
    code_staged = False
    if code and code_out:
        os.makedirs(os.path.dirname(code_out), mode=0o700, exist_ok=True)
        fd, temporary = tempfile.mkstemp(dir=os.path.dirname(code_out), prefix=".sync-code-", suffix=".tmp")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                handle.write(code)
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(temporary, 0o600)
            os.replace(temporary, code_out)
        except BaseException:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass
            raise
        code_staged = True
    return {
        "seed_present": bool(seed),
        "planted": planted,
        "seed_shape": "oscrypt" if looks_oscrypt(seed) else "other",
        "code_staged": code_staged,
    }


def status(prefs_path: str) -> dict:
    prefs = load_preferences(prefs_path)
    seed = seed_of(prefs)
    if seed is None:
        seed = value_at(prefs, LEGACY_SEED_PATH)
    return {"seed_present": isinstance(seed, str) and bool(seed), "seed_shape": "oscrypt" if looks_oscrypt(seed) else "other"}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="ingest-brave-sync")
    parser.add_argument("--env", default="/run/ingest-secret/env")
    parser.add_argument("--prefs", default="/var/lib/brave/profile/Default/Preferences")
    parser.add_argument("--code-out", default="/run/brave/sync-code")
    parser.add_argument("--status", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.status:
            log("status", **status(args.prefs))
            return 0
        summary = stage(args.env, args.prefs, args.code_out)
        log("seed", **summary)
        return 0
    except (OSError, SyncError) as exc:
        log("error", reason=str(exc))
        return 65


if __name__ == "__main__":
    sys.exit(main())
