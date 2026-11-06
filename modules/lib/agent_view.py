"""Assemble the Linux agent VM's view of $HOME from a share_planner plan.

The view is a tmpfs that one virtiofs share exports to the guest: planned shares are
non-recursive bind mounts (read-only ones remounted read-only, enforced by the host
kernel), plain files are read-only file binds, and symlinks are recreated. Anything the
plan leaves out, the deny list above all, has no path in the view at all.

Runs as root from agent-vm-view.service: `share_planner.py ... | agent_view.py --home H --view V`.
"""

import argparse
import json
import os
import posixpath
import stat
import subprocess
import sys
from dataclasses import dataclass


@dataclass(frozen=True)
class Dir:
    rel: str


@dataclass(frozen=True)
class Bind:
    rel: str
    read_only: bool
    is_dir: bool


@dataclass(frozen=True)
class Symlink:
    rel: str
    target: str


def _checked(rel):
    norm = posixpath.normpath(rel) if rel else ""
    if not rel or norm != rel or norm.startswith(("/", "..")) or norm == ".":
        raise ValueError(f"agent_view: unsafe plan path {rel!r}")
    return rel


def _ancestors(rel):
    parts = rel.split("/")[:-1]
    return ["/".join(parts[: i + 1]) for i in range(len(parts))]


def view_ops(plan):
    entries = []
    for share in plan.get("shares", []):
        if share["mode"] not in ("ro", "rw"):
            raise ValueError(f"agent_view: unknown mode {share['mode']!r}")
        entries.append(Bind(_checked(share["rel"]), share["mode"] == "ro", True))
    entries += [Bind(_checked(rel), True, False) for rel in plan.get("copies", [])]
    entries += [
        Symlink(_checked(link["rel"]), link["target"]) for link in plan.get("links", [])
    ]
    dirs = sorted(
        {a for e in entries for a in _ancestors(e.rel)},
        key=lambda rel: (rel.count("/"), rel),
    )
    return [Dir(""), *map(Dir, dirs), *sorted(entries, key=lambda e: e.rel)]


def _mount(*args, pass_fds=()):
    subprocess.run(["mount", *args], check=True, pass_fds=pass_fds)


def _bind(op, home, view):
    source = os.path.join(home, op.rel)
    target = os.path.join(view, op.rel)
    # O_PATH|O_NOFOLLOW pins the inode the plan saw: a path swapped for a symlink since
    # planning cannot redirect a root bind mount elsewhere on the host.
    flags = os.O_PATH | os.O_NOFOLLOW | (os.O_DIRECTORY if op.is_dir else 0)
    try:
        fd = os.open(source, flags)
    except OSError as err:
        print(f"agent_view: skipping {op.rel}: {err}", file=sys.stderr)
        return
    try:
        mode = os.fstat(fd).st_mode
        if not (stat.S_ISDIR(mode) if op.is_dir else stat.S_ISREG(mode)):
            print(f"agent_view: skipping {op.rel}: type changed", file=sys.stderr)
            return
        if op.is_dir:
            os.mkdir(target)
        else:
            open(target, "x").close()
        _mount("--bind", f"/proc/self/fd/{fd}", target, pass_fds=(fd,))
        if op.read_only:
            _mount("-o", "remount,bind,ro,nosuid,nodev", target)
        else:
            _mount("-o", "remount,bind,nosuid,nodev", target)
    finally:
        os.close(fd)


def apply(ops, home, view):
    for op in ops:
        target = os.path.join(view, op.rel) if op.rel else view
        if isinstance(op, Dir):
            st = os.lstat(os.path.join(home, op.rel) if op.rel else home)
            if op.rel:
                os.mkdir(target)
            os.chown(target, st.st_uid, st.st_gid)
            os.chmod(target, stat.S_IMODE(st.st_mode))
        elif isinstance(op, Bind):
            _bind(op, home, view)
        else:
            os.symlink(op.target, target)
            os.lchown(target, *_owner(home))


def _owner(home):
    st = os.stat(home)
    return st.st_uid, st.st_gid


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--home", required=True)
    parser.add_argument("--view", required=True)
    args = parser.parse_args(argv)
    apply(view_ops(json.load(sys.stdin)), args.home, args.view)


if __name__ == "__main__":
    main()
