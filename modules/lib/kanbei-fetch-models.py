#!/usr/bin/env python3
"""Fetch, size-check and hash-check the kanbei model files.

The guest has no NIC and the weights live on the LUKS data volume, so this runs on the host
(inside the mounted volume, see docs/manual-steps.md) or on a workstation whose copy is later
moved into `/var/lib/kanbei/models`. The manifest is the contract
(`modules/lib/kanbei-models.json`, installed in the guest as
`/var/lib/kanbei/models/llama-models.json`); this tool refuses a file whose size or sha256 does
not match it.

Exit codes: 0 every selected model verified; 1 network/IO error; 2 size or hash mismatch.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Iterable

CHUNK = 8 * 1024 * 1024
PROGRESS_EVERY = 512 * 1024 * 1024
DEFAULT_MANIFEST = Path(__file__).with_name("kanbei-models.json")
DEFAULT_ENDPOINT = "https://huggingface.co"
REQUIRED_FIELDS = ("repo", "file", "size", "sha256")


def load_manifest(path: Path) -> dict[str, Any]:
    """Parse and validate the manifest; raises ValueError with a stable message."""
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise ValueError(f"cannot read manifest {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise ValueError(f"manifest {path} is not JSON: {exc}") from exc
    models = data.get("models")
    if not isinstance(models, dict) or not models:
        raise ValueError(f"manifest {path} has no models")
    for name, spec in models.items():
        if not isinstance(spec, dict):
            raise ValueError(f"manifest {path}: model {name} is not an object")
        for field in REQUIRED_FIELDS:
            if field not in spec:
                raise ValueError(f"manifest {path}: model {name} is missing {field}")
        if not isinstance(spec["size"], int) or spec["size"] <= 0:
            raise ValueError(f"manifest {path}: model {name} size is not a positive integer")
        sha = spec["sha256"]
        if not isinstance(sha, str) or len(sha) != 64 or any(c not in "0123456789abcdef" for c in sha):
            raise ValueError(f"manifest {path}: model {name} sha256 is not 64 lowercase hex characters")
        if "/" not in spec["repo"] or not spec["file"]:
            raise ValueError(f"manifest {path}: model {name} repo/file is malformed")
    return data


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for block in iter(lambda: fh.read(CHUNK), b""):
            digest.update(block)
    return digest.hexdigest()


def verify_file(path: Path, spec: dict[str, Any]) -> str | None:
    """Return None when the file matches the manifest, else a human-readable reason."""
    if not path.is_file() or path.is_symlink():
        return f"{path} is missing or not a regular file"
    size = path.stat().st_size
    if size != spec["size"]:
        return f"{path} is {size} bytes, manifest says {spec['size']}"
    digest = sha256_file(path)
    if digest != spec["sha256"]:
        return f"{path} sha256 {digest}, manifest says {spec['sha256']}"
    return None


def download(url: str, dest: Path, spec: dict[str, Any], quiet: bool) -> None:
    part = dest.with_name(dest.name + ".part")
    request = urllib.request.Request(url, headers={"User-Agent": "kanbei-fetch-models/1"})
    digest = hashlib.sha256()
    written = 0
    next_report = PROGRESS_EVERY
    with urllib.request.urlopen(request, timeout=120) as response:
        length = response.headers.get("Content-Length")
        if length is not None and int(length) != spec["size"]:
            raise ValueError(
                f"{url} serves {length} bytes, manifest says {spec['size']}; refusing to download"
            )
        with part.open("wb") as fh:
            for block in iter(lambda: response.read(CHUNK), b""):
                fh.write(block)
                digest.update(block)
                written += len(block)
                if not quiet and written >= next_report:
                    print(f"  {dest.name}: {written / (1024**3):.2f} GiB", file=sys.stderr)
                    next_report += PROGRESS_EVERY
    if written != spec["size"]:
        part.unlink(missing_ok=True)
        raise ValueError(f"{dest.name} downloaded {written} bytes, manifest says {spec['size']}")
    actual = digest.hexdigest()
    if actual != spec["sha256"]:
        # A mismatched file is never installed: the partial is removed, not kept.
        part.unlink(missing_ok=True)
        raise ValueError(f"{dest.name} sha256 {actual}, manifest says {spec['sha256']}")
    os.replace(part, dest)


def selected(data: dict[str, Any], only: Iterable[str] | None) -> list[tuple[str, dict[str, Any]]]:
    models = data["models"]
    if not only:
        return sorted(models.items())
    wanted = list(only)
    unknown = sorted(set(wanted) - set(models))
    if unknown:
        raise ValueError(f"manifest has no model named {', '.join(unknown)}")
    return [(name, models[name]) for name in wanted]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--dest", type=Path, help="target directory (default: the manifest's destination)")
    parser.add_argument("--only", action="append", metavar="NAME", help="fetch only this model (repeatable)")
    parser.add_argument("--check", action="store_true", help="verify what is already there; never download")
    parser.add_argument("--uid", type=int, help="chown the installed files to this uid")
    parser.add_argument("--gid", type=int, help="chgrp the installed files to this gid")
    parser.add_argument("--endpoint", default=os.environ.get("HF_ENDPOINT", DEFAULT_ENDPOINT))
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args(argv)

    try:
        data = load_manifest(args.manifest)
        chosen = selected(data, args.only)
    except ValueError as exc:
        print(f"kanbei-fetch-models: {exc}", file=sys.stderr)
        return 1

    dest = args.dest or Path(data.get("destination", "/var/lib/kanbei/models"))
    if dest.is_symlink():
        print(f"kanbei-fetch-models: {dest} is a symlink; refusing the path contract", file=sys.stderr)
        return 1
    dest.mkdir(parents=True, exist_ok=True)

    status = 0
    for name, spec in chosen:
        target = dest / spec["file"]
        reason = verify_file(target, spec)
        if reason is None:
            if not args.quiet:
                print(f"ok   {name}: {target}")
            continue
        if args.check:
            print(f"FAIL {name}: {reason}", file=sys.stderr)
            status = max(status, 2)
            continue
        url = f"{args.endpoint.rstrip('/')}/{spec['repo']}/resolve/main/{spec['file']}"
        if not args.quiet:
            print(f"get  {name}: {url}", file=sys.stderr)
        try:
            download(url, target, spec, args.quiet)
        except urllib.error.URLError as exc:
            print(f"kanbei-fetch-models: {name}: {exc}", file=sys.stderr)
            status = max(status, 1)
            continue
        except ValueError as exc:
            print(f"kanbei-fetch-models: {name}: {exc}", file=sys.stderr)
            status = max(status, 2)
            continue
        except OSError as exc:
            print(f"kanbei-fetch-models: {name}: {exc}", file=sys.stderr)
            status = max(status, 1)
            continue
        target.chmod(0o640)
        if args.uid is not None or args.gid is not None:
            os.chown(target, -1 if args.uid is None else args.uid, -1 if args.gid is None else args.gid)
        if not args.quiet:
            print(f"ok   {name}: {target} ({spec['size']} bytes, sha256 verified)")
    return status


if __name__ == "__main__":
    sys.exit(main())
