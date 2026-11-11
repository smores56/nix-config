"""Decrypt the phone's receive-encrypted Syncthing folder inside the kanbei guest.

The phone is the trusted Syncthing peer: it encrypts the export tree with a folder
password and shares the resulting ciphertext to the host, which stores it under
``/var/lib/data/phone-untrusted``. This script is the only consumer:

1. Stage the folder password from the host contract (``/run/secrets/phone-folder-password``,
   exposed in the guest at ``/run/kanbei-secrets/phone-folder-password``) into the LUKS
   volume at 0400. A previously staged copy keeps working when the contract is absent.
2. Refuse anything that is not a Syncthing receive-encrypted folder (the folder token is
   the proof; a plaintext folder has none).
3. Run ``syncthing decrypt`` into a fresh work directory with the password in the
   child's environment (never argv), then merge the result into a staging tree (hardlinks
   for unchanged files, copies for new ones), write the manifest and atomically exchange
   the staging tree with ``/var/lib/kanbei/phone``.
4. Deduplicate by content hash and cap each file's size. Newly consumed files produce a
   batch envelope for Kanbei's inbox reader and every successful run updates the
   heartbeat, so a stale phone source is visible instead of silent.

Stdlib only: the guest has no network and no Python packages beyond nixpkgs' python3.
"""

from __future__ import annotations

import argparse
import ctypes
import errno
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

VERSION = 1
SOURCE = "phone"
PASSWORD_MODE = 0o400
MAX_PASSWORD_BYTES = 4096
MAX_BATCH_ITEMS = 500
INTERNAL_NAMES = {".stfolder", ".stignore", ".stversions"}
TOKEN_NAME = "syncthing-encryption_password_token"
TOKEN_REL = Path(".stfolder") / TOKEN_NAME

# Exit codes: the systemd unit surfaces these, and the docs name them.
EXIT_PASSWORD = 10
EXIT_FOLDER = 11
EXIT_DECRYPT = 12
EXIT_CONTRACT = 13


class PhoneDecryptError(Exception):
    def __init__(self, code: int, message: str):
        super().__init__(message)
        self.code = code


def utcnow() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_write(path: Path, data: bytes, mode: int) -> None:
    """Write ``path`` by rename, so a reader never sees a half-written file."""
    directory = path.parent
    directory.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=f".{path.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


def read_password(staged: Path) -> str:
    try:
        info = staged.lstat()
    except FileNotFoundError as exc:
        raise PhoneDecryptError(
            EXIT_PASSWORD,
            f"no folder password: {staged} is missing and no host contract was staged",
        ) from exc
    if not stat.S_ISREG(info.st_mode):
        raise PhoneDecryptError(EXIT_CONTRACT, f"{staged} is not a regular file")
    if stat.S_IMODE(info.st_mode) != PASSWORD_MODE:
        raise PhoneDecryptError(
            EXIT_CONTRACT,
            f"{staged} is {oct(stat.S_IMODE(info.st_mode))}, expected {oct(PASSWORD_MODE)}",
        )
    if info.st_size == 0 or info.st_size > MAX_PASSWORD_BYTES:
        raise PhoneDecryptError(EXIT_CONTRACT, f"{staged} has an implausible size ({info.st_size} bytes)")
    password = staged.read_text("utf-8").rstrip("\r\n")
    if not password:
        raise PhoneDecryptError(EXIT_PASSWORD, f"{staged} is empty")
    return password


def stage_password(contract: Path, staged: Path) -> str:
    """Copy the host contract into the LUKS volume (0400), then return the password.

    The contract is the source of truth; the staged file is the durable copy. A missing
    contract is not fatal once a copy exists, but neither being present is.
    """
    if contract.exists():
        try:
            data = contract.read_bytes()
        except OSError as exc:
            raise PhoneDecryptError(EXIT_CONTRACT, f"cannot read {contract}: {exc}") from exc
        if not data.strip():
            raise PhoneDecryptError(EXIT_CONTRACT, f"{contract} is empty")
        if len(data) > MAX_PASSWORD_BYTES:
            raise PhoneDecryptError(EXIT_CONTRACT, f"{contract} is larger than {MAX_PASSWORD_BYTES} bytes")
        staged.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        atomic_write(staged, data, PASSWORD_MODE)
    return read_password(staged)


def folder_id(folder: Path) -> str:
    """Return the folder id from the receive-encrypted token, or refuse the folder.

    A normal folder has no token (or has plaintext entries), which is exactly the
    "wrong folder type" case: decrypting it would either fail later or, worse, treat a
    plaintext tree as encrypted input.
    """
    if not folder.is_dir():
        raise PhoneDecryptError(EXIT_FOLDER, f"{folder} is not a directory")
    token = folder / TOKEN_REL
    if not token.is_file():
        raise PhoneDecryptError(
            EXIT_FOLDER,
            f"{folder} is not a receive-encrypted folder (missing {TOKEN_REL}); "
            "the phone must share it with a folder password",
        )
    try:
        stored = json.loads(token.read_text("utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise PhoneDecryptError(EXIT_FOLDER, f"{token} is not a valid folder token: {exc}") from exc
    found = stored.get("FolderID") if isinstance(stored, dict) else None
    if not isinstance(found, str) or not found:
        raise PhoneDecryptError(EXIT_FOLDER, f"{token} carries no FolderID")
    for entry in folder.iterdir():
        if entry.name in INTERNAL_NAMES or entry.name.endswith(".syncthing-enc"):
            continue
        raise PhoneDecryptError(
            EXIT_FOLDER,
            f"{folder} contains plaintext entry {entry.name!r}; refusing a non-receive-encrypted folder",
        )
    return found


def decrypt(folder: Path, destination: Path, password: str, syncthing: str) -> None:
    env = os.environ.copy()
    # The CLI reads FOLDER_PASSWORD; argv would expose the password in /proc.
    env["FOLDER_PASSWORD"] = password
    destination.mkdir(parents=True, exist_ok=True)
    proc = subprocess.run(
        [syncthing, "decrypt", "--to", str(destination), str(folder)],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if proc.returncode != 0:
        detail = proc.stderr.decode("utf-8", "replace").strip().replace(password, "<redacted>")
        raise PhoneDecryptError(EXIT_DECRYPT, f"syncthing decrypt failed ({proc.returncode}): {detail[-2000:]}")


def classify(relative: Path, patterns: dict[str, list[re.Pattern[str]]]) -> str | None:
    name = relative.name
    top = relative.parts[0] if len(relative.parts) > 1 else ""
    for kind, regexes in patterns.items():
        if not any(regex.match(name) for regex in regexes):
            continue
        # Raw phone layout: messages/calls under sms/, health under health/, contacts
        # wherever SMS Import/Export wrote them (it can only pick one directory).
        if kind == "health" and top not in ("", "health"):
            return None
        return kind
    return None


def collect(work: Path, max_bytes: int, patterns: dict[str, list[re.Pattern[str]]]):
    accepted: list[tuple[str, Path, str, int]] = []
    rejected: list[dict[str, object]] = []
    for root, dirs, files in os.walk(work):
        dirs[:] = sorted(d for d in dirs if d not in INTERNAL_NAMES)
        for name in sorted(files):
            if name in INTERNAL_NAMES:
                continue
            path = Path(root) / name
            relative = path.relative_to(work)
            kind = classify(relative, patterns)
            if kind is None:
                rejected.append({"path": str(relative), "reason": "unknown-name"})
                continue
            info = path.lstat()
            if not stat.S_ISREG(info.st_mode):
                rejected.append({"path": str(relative), "reason": "not-a-regular-file"})
                continue
            if info.st_size > max_bytes:
                rejected.append({"path": str(relative), "reason": "size-cap", "bytes": info.st_size})
                continue
            accepted.append((kind, path, name, info.st_size))
    return accepted, rejected


def merge_tree(source: Path, target: Path) -> None:
    """Copy ``source`` into the existing tree at ``target`` without deleting anything.

    ``target`` is Kanbei's archive: a phone-side retention run must not erase history.
    Unchanged content is hardlinked so a daily decrypt does not rewrite the whole tree.
    """
    target.mkdir(parents=True, exist_ok=True)
    for root, dirs, files in os.walk(source):
        relative_root = Path(root).relative_to(source)
        destination_root = target / relative_root
        destination_root.mkdir(parents=True, exist_ok=True)
        for name in dirs:
            (destination_root / name).mkdir(exist_ok=True)
        for name in files:
            src = Path(root) / name
            dst = destination_root / name
            tmp = dst.with_name(f".{dst.name}.tmp")
            try:
                os.unlink(tmp)
            except FileNotFoundError:
                pass
            try:
                os.link(src, tmp)
            except OSError:
                shutil.copyfile(src, tmp)
            os.replace(tmp, dst)


def _rename_exchange(left: Path, right: Path) -> None:
    """Atomically exchange two directories (renameat2 RENAME_EXCHANGE)."""
    syscall = {"x86_64": 316, "aarch64": 276}.get(os.uname().machine)
    if syscall is None:
        raise OSError(errno.ENOSYS, "renameat2 is not wired for this architecture")
    libc = ctypes.CDLL(None, use_errno=True)
    at_fdcwd = -100
    rename_exchange = 2
    if libc.syscall(syscall, at_fdcwd, os.fsencode(left), at_fdcwd, os.fsencode(right), rename_exchange) != 0:
        err = ctypes.get_errno()
        raise OSError(err, os.strerror(err))


def swap_dirs(stage: Path, target: Path) -> None:
    """Make ``stage`` the live tree at ``target``, keeping readers on a consistent tree.

    renameat2 exchanges the two directories in one step. The fallback (older kernels or
    filesystems) is two renames, which leaves a sub-millisecond window; the manifest
    inside each tree is what readers should use either way.
    """
    if not target.exists():
        os.rename(stage, target)
        return
    try:
        _rename_exchange(stage, target)
    except OSError:
        retired = target.with_name(f".{target.name}.retired")
        if retired.exists():
            shutil.rmtree(retired)
        os.rename(target, retired)
        os.rename(stage, target)
        shutil.rmtree(retired)
        return
    # After the exchange ``stage`` holds the previous tree.
    shutil.rmtree(stage)


def load_state(path: Path) -> dict[str, object]:
    try:
        state = json.loads(path.read_text("utf-8"))
        if state.get("v") != VERSION or not isinstance(state.get("files"), dict):
            raise ValueError("wrong version")
        state.setdefault("seq", 0)
        return state
    except (FileNotFoundError, ValueError, json.JSONDecodeError, AttributeError):
        return {"v": VERSION, "seq": 0, "files": {}}


def write_batches(batch_dir: Path, seq: int, items: list[dict[str, object]], kind: str, stamp: str) -> int:
    """Write contract-shaped batch envelopes, chunked to MAX_BATCH_ITEMS."""
    batch_dir.mkdir(parents=True, exist_ok=True)
    for start in range(0, max(len(items), 1), MAX_BATCH_ITEMS):
        chunk = items[start : start + MAX_BATCH_ITEMS]
        seq += 1
        envelope = {
            "v": VERSION,
            "source": SOURCE,
            "kind": kind,
            "seq": seq,
            "sent_at": utcnow(),
            "items": chunk,
        }
        name = f"{SOURCE}-{stamp}-{seq:06d}.json"
        atomic_write(batch_dir / name, json.dumps(envelope, sort_keys=True).encode("utf-8"), 0o640)
    return seq


def run(
    *,
    source: Path,
    target: Path,
    contract: Path,
    staged: Path,
    state_path: Path,
    batch_dir: Path,
    heartbeat_path: Path,
    manifest_name: str,
    max_bytes: int,
    patterns: dict[str, list[re.Pattern[str]]],
    syncthing: str,
    stamp: str | None = None,
) -> dict[str, object]:
    stamp = stamp or datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    password = stage_password(contract, staged)
    encrypted_id = folder_id(source)
    state = load_state(state_path)
    known = {entry["sha256"]: rel for rel, entry in state["files"].items() if isinstance(entry, dict) and "sha256" in entry}

    work = Path(tempfile.mkdtemp(prefix=".decrypt-", dir=staged.parent))
    stage = target.with_name(f".{target.name}.stage")
    try:
        decrypt(source, work, password, syncthing)
        accepted, rejected = collect(work, max_bytes, patterns)
        if stage.exists():
            shutil.rmtree(stage)
        stage.mkdir(parents=True)
        if target.is_dir():
            merge_tree(target, stage)

        consumed: list[dict[str, object]] = []
        for kind, path, name, size in accepted:
            digest = sha256_file(path)
            relative = f"{kind}/{name}"
            if digest in known and (stage / relative).is_file():
                continue
            destination = stage / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            tmp = destination.with_name(f".{destination.name}.tmp")
            shutil.copyfile(path, tmp)
            os.chmod(tmp, 0o640)
            os.replace(tmp, destination)
            state["files"][relative] = {
                "sha256": digest,
                "bytes": size,
                "kind": kind,
                "added": utcnow(),
            }
            consumed.append({"kind": kind, "path": relative, "sha256": digest, "bytes": size})

        files = state["files"]
        manifest = {
            "v": VERSION,
            "source": SOURCE,
            "folder_id": encrypted_id,
            "generated_at": utcnow(),
            "files": [{"path": rel, **entry} for rel, entry in sorted(files.items())],
            "rejected": rejected,
        }
        atomic_write(stage / manifest_name, json.dumps(manifest, sort_keys=True).encode("utf-8"), 0o640)
        swap_dirs(stage, target)

        total_bytes = sum(int(entry.get("bytes", 0)) for entry in files.values())
        heartbeat = {
            "v": VERSION,
            "source": SOURCE,
            "status": "ok",
            "ts": utcnow(),
            "seq": int(state["seq"]),
            "files": len(files),
            "bytes": total_bytes,
            "consumed": len(consumed),
        }
        if consumed:
            state["seq"] = write_batches(batch_dir, int(state["seq"]), consumed, "batch", stamp)
            heartbeat["seq"] = int(state["seq"])
        atomic_write(heartbeat_path, json.dumps(heartbeat, sort_keys=True).encode("utf-8"), 0o640)
        atomic_write(state_path, json.dumps(state, sort_keys=True).encode("utf-8"), 0o600)
        return heartbeat
    finally:
        shutil.rmtree(work, ignore_errors=True)
        if stage.exists():
            shutil.rmtree(stage, ignore_errors=True)


def failure_heartbeat(heartbeat_path: Path, batch_dir: Path, seq: int, stamp: str, message: str) -> None:
    heartbeat = {"v": VERSION, "source": SOURCE, "status": "error", "ts": utcnow(), "seq": seq, "error": message[-2000:]}
    try:
        atomic_write(heartbeat_path, json.dumps(heartbeat, sort_keys=True).encode("utf-8"), 0o640)
        write_batches(batch_dir, seq, [{"error": message[-2000:]}], "alert", stamp)
    except OSError:
        pass


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True, help="receive-encrypted Syncthing folder")
    parser.add_argument("--to", type=Path, required=True, help="decrypted tree (manifest + sms/health/contacts)")
    parser.add_argument("--contract", type=Path, required=True)
    parser.add_argument("--staged", type=Path, required=True)
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--batch-dir", type=Path, required=True)
    parser.add_argument("--heartbeat", type=Path, required=True)
    parser.add_argument("--manifest", default="manifest.json")
    parser.add_argument("--max-file-bytes", type=int, required=True)
    parser.add_argument("--syncthing", required=True)
    parser.add_argument("--patterns", type=Path, required=True, help="JSON pattern table written by Nix")
    args = parser.parse_args(argv)

    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    patterns = {
        kind: [re.compile(expression) for expression in expressions]
        for kind, expressions in json.loads(args.patterns.read_text("utf-8")).items()
    }
    try:
        result = run(
            source=args.source,
            target=args.to,
            contract=args.contract,
            staged=args.staged,
            state_path=args.state,
            batch_dir=args.batch_dir,
            heartbeat_path=args.heartbeat,
            manifest_name=args.manifest,
            max_bytes=args.max_file_bytes,
            patterns=patterns,
            syncthing=args.syncthing,
            stamp=stamp,
        )
        print(json.dumps(result, sort_keys=True))
        return 0
    except PhoneDecryptError as exc:
        failure_heartbeat(args.heartbeat, args.batch_dir, 0, stamp, str(exc))
        print(f"syncthing-decrypt: {exc}", file=sys.stderr)
        return exc.code


if __name__ == "__main__":
    sys.exit(main())
