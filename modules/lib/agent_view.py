"""Assemble the Linux agent VM's view of $HOME from a share_planner plan.

The view is a tmpfs that one virtiofs share exports to the guest: planned shares are
non-recursive bind mounts (read-only ones remounted read-only, enforced by the host
kernel) and plain files are read-only file binds. Anything the plan leaves out, everything
outside the allowlist, has no path in the view at all.

Runs as root from agent-vm-prep.service (modules/nixos/agent-vm.nix): `share_planner.py ... | agent_view.py --home H --view V`.
"""

import argparse
import ctypes
import json
import os
import posixpath
import stat
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
    dirs = sorted(
        {a for e in entries for a in _ancestors(e.rel)},
        key=lambda rel: (rel.count("/"), rel),
    )
    return [Dir(""), *map(Dir, dirs), *sorted(entries, key=lambda e: e.rel)]


MS_RDONLY, MS_NOSUID, MS_NODEV, MS_REMOUNT, MS_BIND = 1, 2, 4, 32, 4096
_libc = ctypes.CDLL(None, use_errno=True)


def _mount(source, target, flags):
    # mount(2) directly: util-linux mount(8) canonicalizes a bind source back into a path and
    # re-walks it, which would undo the fd pinning below.
    if _libc.mount(source, target.encode(), None, flags, None) != 0:
        err = ctypes.get_errno()
        raise OSError(err, os.strerror(err), target)


def _open_nofollow(home, rel, leaf_flags):
    """Open home/rel refusing a symlink at every component, ancestors included."""
    fd = os.open(home, os.O_PATH | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        parts = rel.split("/") if rel else []
        for i, part in enumerate(parts):
            last = i == len(parts) - 1
            flags = os.O_PATH | os.O_NOFOLLOW | (leaf_flags if last else os.O_DIRECTORY)
            nxt = os.open(part, flags, dir_fd=fd)
            os.close(fd)
            fd = nxt
        return fd
    except BaseException:
        os.close(fd)
        raise


def _bind(op, home, view, reconcile=False):
    target = os.path.join(view, op.rel)
    # A pinned fd: a path swapped for a symlink after planning cannot redirect a root bind
    # mount elsewhere on the host.
    try:
        fd = _open_nofollow(home, op.rel, os.O_DIRECTORY if op.is_dir else 0)
    except OSError as err:
        print(f"agent_view: skipping {op.rel}: {err}", file=sys.stderr)
        return
    try:
        mode = os.fstat(fd).st_mode
        if not (stat.S_ISDIR(mode) if op.is_dir else stat.S_ISREG(mode)):
            print(f"agent_view: skipping {op.rel}: type changed", file=sys.stderr)
            return
        if op.is_dir:
            if reconcile:
                os.makedirs(target, exist_ok=True)
            else:
                os.mkdir(target)
        else:
            try:
                open(target, "x").close()
            except FileExistsError:
                if not reconcile:
                    raise
        _mount(f"/proc/self/fd/{fd}".encode(), target, MS_BIND)
        flags = MS_REMOUNT | MS_BIND | MS_NOSUID | MS_NODEV
        _mount(None, target, flags | (MS_RDONLY if op.read_only else 0))
    finally:
        os.close(fd)


def apply(ops, home, view, reconcile=False):
    for op in ops:
        target = os.path.join(view, op.rel) if op.rel else view
        if isinstance(op, Dir):
            fd = _open_nofollow(home, op.rel, os.O_DIRECTORY)
            try:
                st = os.fstat(fd)
            finally:
                os.close(fd)
            if op.rel:
                if reconcile:
                    os.makedirs(target, exist_ok=True)
                else:
                    os.mkdir(target)
            os.chown(target, st.st_uid, st.st_gid)
            os.chmod(target, stat.S_IMODE(st.st_mode))
        else:
            if reconcile and os.path.ismount(target):
                continue
            _bind(op, home, view, reconcile)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--home", required=True)
    parser.add_argument("--view", required=True)
    parser.add_argument("--reconcile", action="store_true")
    args = parser.parse_args(argv)
    apply(view_ops(json.load(sys.stdin)), args.home, args.view, args.reconcile)


if __name__ == "__main__":
    main()
