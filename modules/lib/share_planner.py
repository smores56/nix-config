"""Plan which parts of $HOME an agent VM sees (sdlc #386).

VM file shares are whole directories and ignore file modes inside them, so the deny list is the
control: every top-level entry is shared at its own path, and any directory that is an ancestor
of a denied path (or of a read-write path, so that one can get its own mode) is split into its
children. Entries a directory share cannot carry become links (symlinks, recreated in the guest)
or copies (plain files, snapshotted read-only).
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


@dataclass(frozen=True)
class Link:
    rel: str
    target: str


@dataclass
class Plan:
    shares: list = field(default_factory=list)
    links: list = field(default_factory=list)
    copies: list = field(default_factory=list)


def _norm(rel):
    parts = [p for p in rel.split("/") if p not in ("", ".")]
    return "/".join(parts)


def _is_within(rel, roots):
    return any(rel == r or rel.startswith(r + "/") for r in roots)


def _has_descendant(rel, roots):
    return any(r.startswith(rel + "/") for r in roots)


def tag_for(rel):
    # Readable and unique: the slug alone can collide (".a-b" vs "a/b"), the hash suffix cannot.
    # virtio-fs tags are at most 36 bytes, so the slug keeps 29.
    slug = re.sub(r"[^A-Za-z0-9]+", "_", rel).strip("_") or "root"
    return f"{slug[:29]}-{hashlib.sha1(rel.encode()).hexdigest()[:6]}"


def plan(home, deny, rw):
    home = Path(home)
    deny = [d for d in map(_norm, deny) if d]
    rw = [r for r in map(_norm, rw) if r]
    result = Plan()

    def walk(rel_dir):
        base = home / rel_dir if rel_dir else home
        try:
            entries = sorted(os.listdir(base))
        except OSError as err:
            # A split directory must be listed to keep its denied child out; if it cannot be,
            # leaving it out entirely is the only safe answer.
            print(f"share_planner: skipping {rel_dir or '.'}: {err.strerror}", file=sys.stderr)
            return
        for entry in entries:
            rel = f"{rel_dir}/{entry}" if rel_dir else entry
            if _is_within(rel, deny):
                continue
            path = base / entry
            try:
                st = path.lstat()
            except OSError:
                continue  # vanished mid-walk
            if stat.S_ISLNK(st.st_mode):
                result.links.append(Link(rel, os.readlink(path)))
            elif stat.S_ISDIR(st.st_mode):
                if _has_descendant(rel, deny) or _has_descendant(rel, rw):
                    walk(rel)
                else:
                    mode = "rw" if _is_within(rel, rw) else "ro"
                    result.shares.append(Share(rel, mode, tag_for(rel)))
            elif stat.S_ISREG(st.st_mode):
                result.copies.append(rel)
            # Sockets, fifos and devices are host-local; nothing to carry over.

    walk("")
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--home", default=os.environ.get("HOME"))
    parser.add_argument("--deny", action="append", default=[])
    parser.add_argument("--rw", action="append", default=[])
    args = parser.parse_args(argv)
    result = plan(args.home, args.deny, args.rw)
    json.dump(
        {
            "shares": [asdict(s) for s in result.shares],
            "links": [asdict(link) for link in result.links],
            "copies": result.copies,
        },
        sys.stdout,
        indent=2,
    )
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
