"""Plan which parts of $HOME an agent VM sees (sdlc #450).

VM file shares are whole directories and ignore file modes inside them, so the allowlist is the
control: nothing is shared unless it is under an allow root, and a root is either read-only
(`allow`) or read-write (`allowRw`). Ancestors of roots become plain directories in the view, and
a directory that is an ancestor of a root with the other mode is split into its children so each
mode gets its own bind. Roots are deduped to their shallowest ancestor of the same mode; a root
that is a symlink fails closed, and a root that does not exist is skipped with a warning.
"""

import argparse
import hashlib
import json
import os
import re
import stat
import sys
from dataclasses import asdict, dataclass, field
from pathlib import Path


@dataclass(frozen=True)
class Share:
    rel: str
    mode: str  # "ro" or "rw"
    tag: str


@dataclass
class Plan:
    shares: list = field(default_factory=list)
    copies: list = field(default_factory=list)


class PlanError(Exception):
    pass


def _norm(rel):
    parts = [p for p in rel.split("/") if p not in ("", ".")]
    return "/".join(parts)


def _has_descendant(rel, roots):
    return any(r.startswith(rel + "/") for r in roots)


def tag_for(rel):
    # Readable and unique: the slug alone can collide (".a-b" vs "a/b"), the hash suffix cannot.
    # virtio-fs tags are at most 36 bytes, so the slug keeps 29.
    slug = re.sub(r"[^A-Za-z0-9]+", "_", rel).strip("_") or "root"
    return f"{slug[:29]}-{hashlib.sha1(rel.encode()).hexdigest()[:6]}"


def _roots(allow, allow_rw):
    """Map each effective root to its mode, dropping roots covered by a same-mode ancestor."""
    roots = {}
    for rel in map(_norm, allow):
        if rel:
            roots[rel] = "ro"
    # A path in both lists is writable; the caller asked for it.
    for rel in map(_norm, allow_rw):
        if rel:
            roots[rel] = "rw"
    return {
        rel: mode
        for rel, mode in roots.items()
        if not any(
            other != rel and rel.startswith(other + "/") and other_mode == mode
            for other, other_mode in roots.items()
        )
    }


def plan(home, allow, allow_rw):
    home = Path(home)
    roots = _roots(allow, allow_rw)
    result = Plan()

    for rel in roots:
        try:
            st = (home / rel).lstat()
        except OSError as err:
            print(f"share_planner: skipping {rel}: {err.strerror}", file=sys.stderr)
            continue
        if stat.S_ISLNK(st.st_mode):
            raise PlanError(f"{rel} is a symlink; an allow root must be a real path")

    def walk(rel_dir):
        base = home / rel_dir if rel_dir else home
        try:
            entries = sorted(os.listdir(base))
        except OSError as err:
            print(f"share_planner: skipping {rel_dir or '.'}: {err.strerror}", file=sys.stderr)
            return
        for entry in entries:
            rel = f"{rel_dir}/{entry}" if rel_dir else entry
            # The most specific allow root covering the entry decides whether and how it is shared.
            covering = [r for r in roots if rel == r or rel.startswith(r + "/")]
            mode = roots[max(covering, key=len)] if covering else None
            if mode is None and not _has_descendant(rel, roots):
                continue  # outside the allowlist, and no allowed path beneath it
            path = base / entry
            try:
                st = path.lstat()
            except OSError:
                continue  # vanished mid-walk
            if stat.S_ISLNK(st.st_mode):
                raise PlanError(f"{rel} is a symlink on an allow path; refusing to follow it")
            if stat.S_ISDIR(st.st_mode):
                if mode is None or _has_descendant(rel, roots):
                    walk(rel)
                else:
                    result.shares.append(Share(rel, mode, tag_for(rel)))
            elif stat.S_ISREG(st.st_mode):
                if mode is None:
                    raise PlanError(f"{rel} is a file, not a directory, on the way to an allow root")
                result.copies.append(rel)
            elif mode is not None:
                # Sockets, fifos and devices are host-local; nothing to carry over.
                print(f"share_planner: skipping {rel}: not a file or directory", file=sys.stderr)

    walk("")
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--home", default=os.environ.get("HOME"))
    parser.add_argument("--allow", action="append", default=[])
    parser.add_argument("--allow-rw", action="append", default=[])
    args = parser.parse_args(argv)
    try:
        result = plan(args.home, args.allow, args.allow_rw)
    except PlanError as err:
        print(f"share_planner: {err}", file=sys.stderr)
        return 1
    json.dump(
        {
            "shares": [asdict(s) for s in result.shares],
            "links": [],
            "copies": result.copies,
        },
        sys.stdout,
        indent=2,
    )
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
