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


def _env(name: str, default: str) -> str:
    value = os.environ.get(name, "").strip()
    return value or default


# Deployed hosts override these from `config.user.work`; the defaults match the
# personal profile so standalone installs behave the same. Read per call so a
# test (or a supervisor that sets the environment late) sees the current values.
DEFAULT_WORK_FLOW = "pr"
DEFAULT_WORK_EMAIL = "smohr@blitzy.com"
DEFAULT_WORK_OWNER_GLOBS = "blitzy,blitzy-*"
DEFAULT_WORK_SSH_MARKER = "config.work"

_GIT_TIMEOUT = 10
_GROUP_RE = re.compile(r"^[a-z0-9_-]{1,128}$")
_INVALID_GROUP_CHARS = re.compile(r"[^a-z0-9_-]+")
_ACTOR_RE = re.compile(r"^[A-Za-z0-9_-]{1,32}$")
_SCP_REMOTE = re.compile(r"^(?:[^@/]+@)?(?P<host>[^:/]+):(?P<path>.+)$")
_ANSI_ESCAPE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")
_CONTROL = re.compile(r"[\x00-\x1f\x7f\u200e\u200f\u202a-\u202e\u2066-\u2069]")


class GroupRefused(ValueError):
    """The group or directory is malformed, work, or cannot be verified."""


class GitError(RuntimeError):
    """git could not be run or could not answer."""


@dataclass(frozen=True)
class GroupContext:
    group: str
    cwd: str


@dataclass(frozen=True)
class Remote:
    name: str
    url: str
    host: str
    owner: str
    repo: str
    namespace: tuple[str, ...] = ()


@dataclass(frozen=True)
class WorkSettings:
    flow: str
    email: str
    owner_globs: tuple[str, ...]
    ssh_marker: str

    @property
    def email_domain(self) -> str:
        return self.email.rsplit("@", 1)[-1].lower() if "@" in self.email else self.email.lower()


def work_settings() -> WorkSettings:
    return WorkSettings(
        flow=_env("MEMORY_WORK_FLOW", DEFAULT_WORK_FLOW),
        email=_env("MEMORY_WORK_EMAIL", DEFAULT_WORK_EMAIL),
        owner_globs=tuple(
            part.strip()
            for part in _env("MEMORY_WORK_OWNER_GLOB", DEFAULT_WORK_OWNER_GLOBS).split(",")
            if part.strip()
        ),
        ssh_marker=_env("MEMORY_WORK_SSH_MARKER", DEFAULT_WORK_SSH_MARKER),
    )


def owner_is_work(owner: str, settings: WorkSettings | None = None) -> bool:
    lowered = owner.lower()
    globs = (settings or work_settings()).owner_globs
    return any(fnmatch.fnmatchcase(lowered, pattern.lower()) for pattern in globs)


def work_reason_for_group(group: str, settings: WorkSettings | None = None) -> str | None:
    lowered = group.lower()
    if lowered == "work" or lowered.startswith("work:"):
        return "work groups are refused"
    owner = lowered.split("--", 1)[0]
    if owner == "work" or owner_is_work(owner, settings):
        return f"owner {owner!r} belongs to the employer"
    return None


def validate_group(group: str) -> str:
    """Validate and canonicalize a group name.

    Case is folded so `Global`/`GLOBAL` and `Owner--Repo` cannot create a second
    group that shadows the canonical one.
    """
    candidate = (group or "").strip().lower()
    if not _GROUP_RE.fullmatch(candidate):
        raise GroupRefused("group must match ^[a-z0-9_-]{1,128}$")
    reason = work_reason_for_group(candidate)
    if reason:
        raise GroupRefused(f"{reason}: {candidate}")
    return candidate


def sanitize_actor(actor: str | None) -> str:
    candidate = (actor or "").strip().lower()
    return candidate if _ACTOR_RE.fullmatch(candidate) else "unknown"


def sanitize_cwd(value: str | None) -> str:
    """Keep one absolute-looking line, with control, BiDi, and ANSI escapes removed."""
    raw = str(value or "")
    first_line = raw.splitlines()[0] if raw else ""
    return _CONTROL.sub("", _ANSI_ESCAPE.sub("", first_line)).strip()


def sanitize_slug(value: str) -> str:
    cleaned = _INVALID_GROUP_CHARS.sub("-", value.lower()).strip("-")
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
    return Remote(name=name, url=raw, host=host, owner=parts[-2], repo=repo, namespace=tuple(parts[:-1]))


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
    except FileNotFoundError as exc:
        raise GitError("git is not installed") from exc
    except subprocess.TimeoutExpired as exc:
        raise GitError(f"git timed out after {_GIT_TIMEOUT}s") from exc
    except OSError as exc:
        raise GitError(f"cannot run git: {exc}") from exc


def _git_value(cwd: str, *args: str, env: dict[str, str] | None = None) -> str | None:
    result = _run_git(cwd, *args, env=env)
    if result.returncode != 0:
        return None
    value = result.stdout.strip()
    return value or None


def _git_config(cwd: str, key: str, env: dict[str, str] | None = None) -> str | None:
    return _git_value(cwd, "config", "--get", key, env=env)


def _has_git_marker(path: str) -> bool:
    """Filesystem-only check: is this path inside a git worktree?

    Used when git itself cannot answer, so a broken git cannot make a work
    checkout look like an ordinary directory.
    """
    candidate = Path(os.path.abspath(path))
    return any((directory / ".git").exists() for directory in (candidate, *candidate.parents))


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
    """Return the worktree root, None outside a repo, and raise GitError on probe failure."""
    result = _run_git(cwd, "rev-parse", "--is-inside-work-tree", env=env)
    if result.returncode != 0:
        if "not a git repository" in result.stderr.lower() and not _has_git_marker(cwd):
            return None
        raise GitError(result.stderr.strip() or f"git rev-parse exited {result.returncode}")
    if result.stdout.strip() != "true":
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

    Fail closed: one marker is enough. Every remote is checked on every entry,
    on any host and through any SSH alias, so a fork with a work upstream is
    work even when its own URL looks personal.
    """
    remotes = _remotes(cwd, env)
    settings = work_settings()

    flow = _git_config(cwd, "smores.flow", env)
    if flow == settings.flow:
        return f"smores.flow={flow}"

    email = _git_config(cwd, "user.email", env)
    if email and email.lower().endswith("@" + settings.email_domain):
        return f"user.email ends with @{settings.email_domain}"

    ssh_command = _git_config(cwd, "core.sshCommand", env)
    if ssh_command and settings.ssh_marker in ssh_command:
        return f"core.sshCommand references {settings.ssh_marker}"

    for remote in remotes:
        for part in remote.namespace:
            if owner_is_work(part, settings):
                return f"remote {remote.name} points at {remote.host}/{part}"
    return None


def _local_slug(root: str) -> str:
    name = Path(root).name or "root"
    return f"local--{sanitize_slug(name)}"


def derive_group(cwd: str, env: dict[str, str] | None = None) -> GroupContext:
    """Derive the project group for a cwd, refusing work directories.

    A git probe that fails inside a worktree is refused, not downgraded to a
    local group: a broken git must not hide the employer's remote.
    """
    absolute = os.path.abspath(cwd)
    if not os.path.isdir(absolute):
        raise GroupRefused(f"not a directory: {absolute}")

    try:
        marker = work_marker(absolute, env)
        if marker:
            raise GroupRefused(f"refusing work directory {absolute} ({marker})")
        root = repo_root_for(absolute, env)
        if root is None:
            return GroupContext(group=_local_slug(absolute), cwd=absolute)
        remotes = _remotes(root, env)
    except GitError as exc:
        if _has_git_marker(absolute):
            raise GroupRefused(
                f"refusing {absolute}: {exc}, and the directory is inside a git worktree, "
                "so work status cannot be verified"
            ) from exc
        return GroupContext(group=_local_slug(absolute), cwd=absolute)

    remote = _primary_remote(remotes)
    group = _local_slug(root) if remote is None else f"{sanitize_slug(remote.owner)}--{sanitize_slug(remote.repo)}"
    return GroupContext(group=validate_group(group), cwd=absolute)
