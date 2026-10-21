"""Derive a memory group from a working directory and classify work repos.

The MCP HTTP client in Maki sends no cwd and no roots, but its stdio client
inherits the process cwd. The shim therefore derives the group locally and the
server only validates it. Work classification deliberately reads git config and
every remote instead of matching path strings: a personal clone of a work fork
still has the employer's upstream, and a work clone can live anywhere.
"""

from __future__ import annotations

import fnmatch
import os
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlparse

GLOBAL_GROUP = "global"
WORK_FLOW = "pr"
WORK_EMAIL_DOMAIN = "blitzy.com"
WORK_OWNER_GLOBS = ("blitzy", "blitzy-*")
WORK_SSH_MARKER = "config.work"
GITHUB_HOSTS = ("github.com",)

_GIT_TIMEOUT = 10
_GROUP_RE = re.compile(r"^[A-Za-z0-9_-]{1,128}$")
_INVALID_GROUP_CHARS = re.compile(r"[^A-Za-z0-9_-]+")
_ACTOR_RE = re.compile(r"^[A-Za-z0-9_-]{1,32}$")
_SCP_REMOTE = re.compile(r"^(?:[^@/]+@)?(?P<host>[^:/]+):(?P<path>.+)$")


class WorkRefused(RuntimeError):
    """The directory or group belongs to the employer; memory must not touch it."""


class GroupRefused(ValueError):
    """The group is malformed or is a work group."""


@dataclass(frozen=True)
class GroupContext:
    group: str
    cwd: str
    repo_root: str | None


@dataclass(frozen=True)
class Remote:
    name: str
    url: str
    host: str
    owner: str
    repo: str


def owner_is_work(owner: str) -> bool:
    lowered = owner.lower()
    return any(fnmatch.fnmatchcase(lowered, pattern) for pattern in WORK_OWNER_GLOBS)


def work_reason_for_group(group: str) -> str | None:
    lowered = group.lower()
    if lowered == "work" or lowered.startswith("work:"):
        return "work groups are refused"
    owner = lowered.split("--", 1)[0]
    if owner == "work" or owner_is_work(owner):
        return f"owner {owner!r} belongs to the employer"
    return None


def validate_group(group: str) -> str:
    candidate = group.strip()
    if not _GROUP_RE.fullmatch(candidate):
        raise GroupRefused("group must match ^[A-Za-z0-9_-]{1,128}$")
    reason = work_reason_for_group(candidate)
    if reason:
        raise GroupRefused(f"{reason}: {candidate}")
    return candidate


def sanitize_actor(actor: str | None) -> str:
    candidate = (actor or "").strip().lower()
    return candidate if _ACTOR_RE.fullmatch(candidate) else "unknown"


def sanitize_slug(value: str) -> str:
    cleaned = _INVALID_GROUP_CHARS.sub("-", value).strip("-")
    return (cleaned or "unknown")[:60]


def parse_remote(name: str, url: str) -> Remote | None:
    """Parse the SSH, scp, and HTTPS spellings git accepts into host/owner/repo."""
    raw = url.strip()
    if not raw or raw.startswith("file://"):
        return None

    host = ""
    path = ""
    if "://" in raw:
        parsed = urlparse(raw)
        if not parsed.hostname:
            return None
        host = parsed.hostname.lower()
        path = parsed.path
    else:
        match = _SCP_REMOTE.match(raw)
        if not match:
            return None
        host = match.group("host").lower()
        path = match.group("path")

    parts = [part for part in path.split("/") if part]
    if len(parts) < 2:
        return None
    repo = parts[-1]
    if repo.endswith(".git"):
        repo = repo[: -len(".git")]
    if not repo:
        return None
    return Remote(name=name, url=raw, host=host, owner=parts[-2], repo=repo)


def _run_git(cwd: str, *args: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            ["git", "-C", cwd, *args],
            capture_output=True,
            text=True,
            env=env,
            timeout=_GIT_TIMEOUT,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return subprocess.CompletedProcess(args, returncode=1, stdout="", stderr=str(exc))


def _git_value(cwd: str, *args: str, env: dict[str, str] | None = None) -> str | None:
    result = _run_git(cwd, *args, env=env)
    if result.returncode != 0:
        return None
    value = result.stdout.strip()
    return value or None


def _git_config(cwd: str, key: str, env: dict[str, str] | None = None) -> str | None:
    return _git_value(cwd, "config", "--get", key, env=env)


def _remotes(cwd: str, env: dict[str, str] | None = None) -> list[Remote]:
    output = _git_value(cwd, "remote", "-v", env=env)
    if not output:
        return []
    seen: set[tuple[str, str]] = set()
    remotes: list[Remote] = []
    for line in output.splitlines():
        fields = line.split()
        if len(fields) < 2:
            continue
        name, url = fields[0], fields[1]
        if (name, url) in seen:
            continue
        seen.add((name, url))
        parsed = parse_remote(name, url)
        if parsed:
            remotes.append(parsed)
    return remotes


def repo_root_for(cwd: str, env: dict[str, str] | None = None) -> str | None:
    inside = _git_value(cwd, "rev-parse", "--is-inside-work-tree", env=env)
    if inside != "true":
        return None
    if ".worktrees" in Path(cwd).parts:
        common = _git_value(cwd, "rev-parse", "--path-format=absolute", "--git-common-dir", env=env)
        if common:
            common_path = Path(common)
            return str(common_path.parent if common_path.name == ".git" else common_path)
    top = _git_value(cwd, "rev-parse", "--show-toplevel", env=env)
    return top or None


def _primary_remote(remotes: list[Remote]) -> Remote | None:
    for preferred in ("origin", "upstream"):
        for remote in remotes:
            if remote.name == preferred:
                return remote
    return remotes[0] if remotes else None


def work_marker(cwd: str, env: dict[str, str] | None = None) -> str | None:
    """Return the first employer signal, or None.

    Fail closed: one marker is enough. Remotes are checked on every entry, so a
    fork with a work upstream is work even when its own URL looks personal.
    """
    remotes = _remotes(cwd, env)

    flow = _git_config(cwd, "smores.flow", env)
    if flow == WORK_FLOW:
        return f"smores.flow={flow}"

    email = _git_config(cwd, "user.email", env)
    if email and email.lower().endswith("@" + WORK_EMAIL_DOMAIN):
        return f"user.email ends with @{WORK_EMAIL_DOMAIN}"

    ssh_command = _git_config(cwd, "core.sshCommand", env)
    if ssh_command and WORK_SSH_MARKER in ssh_command:
        return f"core.sshCommand references {WORK_SSH_MARKER}"

    for remote in remotes:
        if remote.host in GITHUB_HOSTS and owner_is_work(remote.owner):
            return f"remote {remote.name} points at {remote.host}/{remote.owner}"
    return None


def _local_slug(root: str) -> str:
    name = Path(root).name or "root"
    return f"local--{sanitize_slug(name)}"


def derive_group(cwd: str, env: dict[str, str] | None = None) -> GroupContext:
    """Derive the project group for a cwd, refusing work directories."""
    absolute = os.path.abspath(cwd)
    if not os.path.isdir(absolute):
        raise GroupRefused(f"not a directory: {absolute}")

    marker = work_marker(absolute, env)
    if marker:
        raise WorkRefused(f"refusing work directory {absolute} ({marker})")

    root = repo_root_for(absolute, env)
    if root is None:
        return GroupContext(group=_local_slug(absolute), cwd=absolute, repo_root=None)

    remote = _primary_remote(_remotes(root, env))
    group = _local_slug(root) if remote is None else f"{sanitize_slug(remote.owner)}--{sanitize_slug(remote.repo)}"
    return GroupContext(group=validate_group(group), cwd=absolute, repo_root=root)
