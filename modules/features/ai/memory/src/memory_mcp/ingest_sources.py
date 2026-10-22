"""Corpus adapters for `memory ingest`: sdlc issues, personal notes, repo docs.

Each adapter is pure over an injected fetcher (`run_gh`, a filesystem walk), so
the mapping and chunking are testable without the network. Every episode
carries the group it belongs to and a stable `source_id`; the runner adds the
content hash and provenance headers.

Two safety rules live here: work repositories are refused by the same marker
logic the cwd path uses (a personal fork still has the employer's upstream),
and no path is read through a symlink that leaves the corpus root.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Iterable

from .chunking import (
    document_title,
    episode_content,
    is_json_document,
    sections_for,
    source_ids,
)
from .groups import (
    GLOBAL_GROUP,
    GitError,
    GroupRefused,
    owner_is_work,
    sanitize_slug,
    validate_group,
    work_marker,
)

DEFAULT_PERSONAL_OWNER = "smores56"
MAX_DOC_BYTES = 200_000
COMMENT_MIN_CHARS = 20
GH_TIMEOUT_SECONDS = 120
ISSUE_LIMIT = 1000
REPO_LIMIT = 200

SKIP_DIRS = frozenset(
    {
        ".git",
        ".worktrees",
        ".direnv",
        ".cache",
        "node_modules",
        "vendor",
        "target",
        "build",
        "dist",
        "result",
        "__pycache__",
    }
)

PART_OF = re.compile(r"Part of #(\d+)", re.IGNORECASE)
# A task body that is nothing but a parent pointer: the title says everything.
PARENT_POINTER_ONLY = re.compile(r"^Part of #\d+\.?$", re.IGNORECASE)
REPO_LABEL = re.compile(r"^repo:(.+)$", re.IGNORECASE)
COMMENT_ID = re.compile(r"issuecomment-(\d+)")

ISSUE_FIELDS = "number,title,body,labels,comments,url,createdAt,updatedAt"


class SourceError(RuntimeError):
    """A corpus source could not be read; the ingest should stop, not skip silently."""


@dataclass(frozen=True)
class Episode:
    source: str
    source_id: str
    group: str
    content: str
    tags: tuple[str, ...] = ()
    kind: str = "text"
    valid_at: str = ""


@dataclass(frozen=True)
class Skip:
    source: str
    source_id: str
    reason: str


@dataclass(frozen=True)
class Plan:
    source: str
    episodes: list[Episode] = field(default_factory=list)
    skipped: list[Skip] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    def limited(self, limit: int | None) -> Plan:
        if limit is None or limit <= 0 or len(self.episodes) <= limit:
            return self
        return Plan(
            source=self.source,
            episodes=self.episodes[:limit],
            skipped=self.skipped,
            warnings=self.warnings,
        )


def personal_owner() -> str:
    """The GitHub user whose repos and sdlc registry are ingested.

    Deployed hosts set `MEMORY_PERSONAL_OWNER` from `config.user.githubUser`;
    the default keeps a standalone install working.
    """
    return os.environ.get("MEMORY_PERSONAL_OWNER", "").strip() or DEFAULT_PERSONAL_OWNER


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def utc_timestamp(value: object) -> str:
    """Normalize an ISO timestamp to UTC Z; empty when it cannot be read."""
    text = str(value or "").strip()
    if not text:
        return ""
    try:
        moment = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return ""
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=timezone.utc)
    return moment.astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def file_timestamp(path: Path) -> str:
    try:
        moment = datetime.fromtimestamp(path.stat().st_mtime, tz=timezone.utc)
    except OSError:
        return ""
    return moment.isoformat(timespec="seconds").replace("+00:00", "Z")


def git_last_commit(repo_root: Path, relpath: str) -> str:
    """The last commit time for one file, or empty outside git or on failure."""
    try:
        result = subprocess.run(
            ["git", "-C", str(repo_root), "log", "-1", "--format=%cI", "--", relpath],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    if result.returncode != 0:
        return ""
    return utc_timestamp(result.stdout.strip())


def kind_for(body: str) -> str:
    return "json" if is_json_document(body.strip()) else "text"


def sdlc_repo() -> str:
    return f"{personal_owner()}/sdlc"


def sdlc_group() -> str:
    return f"{personal_owner()}--sdlc"


def _warn(message: str) -> None:
    print(f"memory ingest: warning: {message}", file=sys.stderr)


def run_gh(args: Iterable[str]) -> str:
    argv = list(args)
    try:
        result = subprocess.run(
            ["gh", *argv],
            capture_output=True,
            text=True,
            timeout=GH_TIMEOUT_SECONDS,
            check=False,
        )
    except FileNotFoundError as exc:
        raise SourceError("gh is not installed; sdlc and remote-doc ingestion need it") from exc
    except subprocess.TimeoutExpired as exc:
        raise SourceError(f"gh timed out after {GH_TIMEOUT_SECONDS}s") from exc
    if result.returncode != 0:
        message = result.stderr.strip() or f"gh exited {result.returncode}"
        raise SourceError(f"gh {argv[0]} failed: {message[:300]}")
    return result.stdout


def gh_json(args: Iterable[str]) -> object:
    try:
        return json.loads(run_gh(args))
    except json.JSONDecodeError as exc:
        raise SourceError(f"gh returned invalid JSON: {exc}") from exc


def fetch_issues(runner: Callable[[Iterable[str]], str] = run_gh) -> list[dict[str, object]]:
    payload = runner(
        ["issue", "list", "--repo", sdlc_repo(), "--state", "all", "--limit", str(ISSUE_LIMIT), "--json", ISSUE_FIELDS]
    )
    try:
        issues = json.loads(payload) if isinstance(payload, str) else payload
    except json.JSONDecodeError as exc:
        raise SourceError(f"gh issue list returned invalid JSON: {exc}") from exc
    if not isinstance(issues, list):
        raise SourceError("gh issue list did not return a list")
    filtered = [issue for issue in issues if isinstance(issue, dict)]
    if len(issues) >= ISSUE_LIMIT:
        _warn(
            f"gh issue list returned exactly the {ISSUE_LIMIT}-issue limit; the list may be truncated"
        )
    return filtered


def issue_number(issue: dict[str, object]) -> int:
    return int(issue["number"])  # type: ignore[arg-type]


def _labels(issue: dict[str, object]) -> list[str]:
    labels = issue.get("labels")
    if not isinstance(labels, list):
        return []
    return [str(label.get("name", "")) for label in labels if isinstance(label, dict)]


def repo_labels(issue: dict[str, object]) -> list[str]:
    """Every `repo:` label on the issue, in label order.

    An issue can point at several repos; picking one silently would file its
    episodes under an arbitrary group, so the caller writes to all of them.
    """
    found: list[str] = []
    for label in _labels(issue):
        match = REPO_LABEL.match(label)
        if match:
            candidate = match.group(1).strip()
            if candidate and candidate not in found:
                found.append(candidate)
    return found


def group_for_repo_label(repo: str) -> str | None:
    """Map a `repo:` label to a personal group, refusing employer-owned repos."""
    candidate = repo.strip()
    if "--" in candidate:
        owner, name = candidate.split("--", 1)
    else:
        owner, name = personal_owner(), candidate
    if not name or owner_is_work(owner) or owner_is_work(name):
        return None
    try:
        return validate_group(f"{owner}--{sanitize_slug(name)}")
    except GroupRefused:
        return None


def parent_number(issue: dict[str, object]) -> int | None:
    match = PART_OF.search(str(issue.get("body") or ""))
    return int(match.group(1)) if match else None


def resolve_groups(
    number: int, issues: dict[int, dict[str, object]], seen: frozenset[int] = frozenset()
) -> list[tuple[str, str]]:
    """Resolve every group for an issue, following `Part of #N` when unlabeled.

    Returns one `(group, reason)` pair per label; `group` is empty when the
    label belongs to the employer, which the caller reports as a skip.
    """
    issue = issues.get(number)
    if issue is None:
        return [(sdlc_group(), "parent not in the issue list")]
    labels = repo_labels(issue)
    if labels:
        resolved: list[tuple[str, str]] = []
        for label in labels:
            group = group_for_repo_label(label)
            if group is None:
                resolved.append(("", f"repo label {label!r} belongs to the employer"))
            elif all(existing != group for existing, _reason in resolved):
                resolved.append((group, f"repo:{label}"))
        return resolved
    parent = parent_number(issue)
    if parent is None or parent in seen:
        return [(sdlc_group(), "no repo label")]
    return resolve_groups(parent, issues, seen | {number})


def _comment_id(comment: dict[str, object], index: int) -> str:
    url = str(comment.get("url") or "")
    match = COMMENT_ID.search(url)
    if match:
        return match.group(1)
    raw = re.sub(r"[^A-Za-z0-9_-]+", "", str(comment.get("id") or ""))
    return raw or str(index + 1)


def _issue_body_episode(
    number: int,
    issue: dict[str, object],
    title: str,
    ref: str,
    group: str,
    valid_at: str,
) -> Episode:
    """One episode for a body with no section of its own.

    Short task bodies ("Part of #215.") and empty feature bodies would otherwise
    be dropped, which loses the task's link and title entirely. A one-line body
    that only points at a parent adds nothing to the title, so it uses the
    title alone; any other body is kept under it.
    """
    body = str(issue.get("body") or "").strip()
    compact = " ".join(body.split())
    body_only_points_at_parent = bool(compact) and PARENT_POINTER_ONLY.fullmatch(compact) is not None
    retained = "" if body_only_points_at_parent else body
    kind = kind_for(retained)
    # A JSON document must reach Graphiti as pure JSON so the json extraction
    # prompt sees valid input; provenance stays in the registry.
    content = retained if kind == "json" else episode_content(ref, title, "", retained)
    return Episode(
        source="sdlc",
        source_id=f"issue-{number}#body",
        group=group,
        content=content,
        tags=("sdlc", f"issue-{number}"),
        kind=kind,
        valid_at=valid_at,
    )


def _issue_episodes(issue: dict[str, object], group: str) -> list[Episode]:
    number = issue_number(issue)
    title = str(issue.get("title") or f"issue {number}")
    ref = f"{sdlc_repo()}#{number}"
    tags = ("sdlc", f"issue-{number}")
    episodes: list[Episode] = []
    issue_valid = (
        utc_timestamp(issue.get("createdAt"))
        or utc_timestamp(issue.get("updatedAt"))
        or _now_iso()
    )

    body = str(issue.get("body") or "").strip()
    sections = sections_for(body)
    if not sections:
        episodes.append(_issue_body_episode(number, issue, title, ref, group, issue_valid))
    else:
        for section, source_id in zip(sections, source_ids(f"issue-{number}", sections)):
            kind = kind_for(section.body)
            content = (
                section.body
                if kind == "json"
                else episode_content(ref, title, section.label, section.body)
            )
            episodes.append(
                Episode(
                    source="sdlc",
                    source_id=source_id,
                    group=group,
                    content=content,
                    tags=tags,
                    kind=kind,
                    valid_at=issue_valid,
                )
            )

    comments = issue.get("comments")
    if isinstance(comments, list):
        for index, comment in enumerate(comments):
            if not isinstance(comment, dict):
                continue
            text = str(comment.get("body") or "").strip()
            if len(text) <= COMMENT_MIN_CHARS:
                continue
            author = str((comment.get("author") or {}).get("login") or "unknown")
            created = str(comment.get("createdAt") or "")
            comment_valid = utc_timestamp(created) or issue_valid
            url = str(comment.get("url") or "")
            base = f"issue-{number}#comment-{_comment_id(comment, index)}"
            comment_sections = sections_for(text, min_chars=1)
            for section, source_id in zip(
                comment_sections, source_ids(base, comment_sections)
            ):
                kind = kind_for(section.body)
                if kind == "json":
                    content = section.body
                else:
                    label = f"comment by {author} on {(created or comment_valid)[:10]}"
                    if section.label:
                        label += f" — {section.label}"
                    content = episode_content(
                        f"{ref} ({url})" if url else ref, title, label, section.body
                    )
                episodes.append(
                    Episode(
                        source="sdlc",
                        source_id=source_id,
                        group=group,
                        content=content,
                        tags=tags,
                        kind=kind,
                        valid_at=comment_valid,
                    )
                )
    return episodes


def sdlc_plan(issues: list[dict[str, object]]) -> Plan:
    ordered = sorted(issues, key=issue_number)
    by_number = {issue_number(issue): issue for issue in ordered}
    episodes: list[Episode] = []
    skipped: list[Skip] = []
    for issue in ordered:
        number = issue_number(issue)
        for group, reason in resolve_groups(number, by_number):
            if not group:
                skipped.append(Skip("sdlc", f"issue-{number}", reason))
                continue
            episodes.extend(_issue_episodes(issue, group))
    return Plan(source="sdlc", episodes=episodes, skipped=skipped)


def _contained(path: Path, root: Path) -> bool:
    """Whether `path` resolves inside `root` (symlinks included)."""
    try:
        resolved = path.resolve()
        root_resolved = root.resolve()
    except OSError:
        return False
    return resolved == root_resolved or root_resolved in resolved.parents


def notes_plan(notes_dir: str) -> Plan:
    root = Path(notes_dir).expanduser()
    if not root.is_dir():
        raise SourceError(f"notes directory not found: {root}")
    episodes: list[Episode] = []
    skipped: list[Skip] = []
    for path in sorted(root.rglob("*.md")):
        rel = path.relative_to(root)
        ref = f"note:{rel}"
        if path.is_symlink() and not _contained(path, root):
            skipped.append(Skip("notes", f"{ref}#body", "symlink resolves outside the notes directory"))
            continue
        if not _contained(path, root):
            skipped.append(Skip("notes", f"{ref}#body", "path resolves outside the notes directory"))
            continue
        if not path.is_file():
            if path.is_symlink():
                skipped.append(Skip("notes", f"{ref}#body", "unreadable: broken symlink"))
            continue
        try:
            size = path.stat().st_size
        except OSError as exc:
            skipped.append(Skip("notes", f"{ref}#body", f"unreadable: {exc}"))
            continue
        if size > MAX_DOC_BYTES:
            skipped.append(Skip("notes", f"{ref}#body", "file exceeds 200 KB"))
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError as exc:
            skipped.append(Skip("notes", f"{ref}#body", f"unreadable: {exc}"))
            continue
        title = document_title(text, path.stem)
        sections = sections_for(text)
        if not sections:
            skipped.append(Skip("notes", f"{ref}#body", "file is empty or boilerplate"))
            continue
        valid_at = file_timestamp(path) or _now_iso()
        for section, source_id in zip(sections, source_ids(ref, sections)):
            episodes.append(
                Episode(
                    source="notes",
                    source_id=source_id,
                    group=GLOBAL_GROUP,
                    content=episode_content(ref, title, section.label, section.body),
                    tags=("notes",),
                    kind="text",
                    valid_at=valid_at,
                )
            )
    return Plan(source="notes", episodes=episodes, skipped=skipped)


def local_doc_files(repo_root: Path) -> list[Path]:
    """README, AGENTS, and docs/**/*.md, skipping generated, vendor, and symlinked paths."""
    files: list[Path] = []
    for name in ("README.md", "AGENTS.md"):
        candidate = repo_root / name
        if candidate.is_file() and not candidate.is_symlink() and _contained(candidate, repo_root):
            files.append(candidate)
    docs = repo_root / "docs"
    if docs.is_dir():
        for current, dirs, names in os.walk(docs):
            dirs[:] = sorted(
                directory
                for directory in dirs
                if directory not in SKIP_DIRS
                and not directory.startswith("result-")
                and not (Path(current) / directory).is_symlink()
            )
            for name in sorted(names):
                if name.endswith(".md"):
                    candidate = Path(current) / name
                    if not candidate.is_symlink() and _contained(candidate, repo_root):
                        files.append(candidate)
    return files


def _doc_episodes(
    *,
    repo: str,
    relpath: str,
    text: str,
    source: str = "docs",
    valid_at: str = "",
) -> tuple[list[Episode], list[Skip]]:
    group = validate_group(f"{personal_owner()}--{sanitize_slug(repo)}")
    title = document_title(text, Path(relpath).name)
    ref = f"{personal_owner()}/{repo}/{relpath}"
    base = f"repo:{repo}:{relpath}"
    episodes: list[Episode] = []
    skipped: list[Skip] = []
    sections = sections_for(text)
    if not sections:
        skipped.append(Skip(source, f"{base}#body", "file is empty or boilerplate"))
        return episodes, skipped
    for section, source_id in zip(sections, source_ids(base, sections)):
        episodes.append(
            Episode(
                source=source,
                source_id=source_id,
                group=group,
                content=episode_content(ref, title, section.label, section.body),
                tags=("docs", sanitize_slug(repo)),
                kind="text",
                valid_at=valid_at or _now_iso(),
            )
        )
    return episodes, skipped


def gh_api(path: str, accept: str) -> str:
    return run_gh(["api", path, "-H", f"Accept: {accept}"])


def repo_readme(repo: str) -> str | None:
    """The repo README, or None when the repo has none.

    Only a 404 is a skip: an auth, rate-limit, or network error must fail the
    docs source instead of silently dropping every remaining README.
    """
    try:
        return gh_api(f"repos/{personal_owner()}/{repo}/readme", "application/vnd.github.raw")
    except SourceError as exc:
        message = str(exc)
        if "HTTP 404" in message or "Not Found" in message or "Not found" in message:
            return None
        raise


def personal_repos() -> list[dict[str, object]]:
    payload = gh_json(
        ["repo", "list", personal_owner(), "--limit", str(REPO_LIMIT), "--json", "name,isArchived,isFork,description"]
    )
    if not isinstance(payload, list):
        raise SourceError("gh repo list did not return a list")
    if len(payload) >= REPO_LIMIT:
        _warn(f"gh repo list returned exactly the {REPO_LIMIT}-repo limit; the list may be truncated")
    return [repo for repo in payload if isinstance(repo, dict)]


def _refuse_work_clone(repo_root: Path, repo: str) -> Skip | None:
    """Skip a local clone that the shared work-marker logic calls work."""
    marker = work_marker(str(repo_root))
    if marker:
        return Skip("docs", f"repo:{repo}", f"work repository ({marker}); refused")
    return None


def docs_plan(
    docs_root: str,
    *,
    repos: set[str] | None = None,
    list_repos: Callable[[], list[dict[str, object]]] = personal_repos,
    read_readme: Callable[[str], str | None] = repo_readme,
) -> Plan:
    root = Path(docs_root).expanduser()
    if not root.is_dir():
        raise SourceError(f"docs root not found: {root}")
    episodes: list[Episode] = []
    skipped: list[Skip] = []
    covered: set[str] = set()

    for repo_root in sorted((path for path in root.iterdir() if path.is_dir()), key=lambda path: path.name):
        repo = repo_root.name
        if repos is not None and repo not in repos:
            continue
        if repo_root.is_symlink() or not _contained(repo_root, root):
            skipped.append(Skip("docs", f"repo:{repo}", "symlinked or resolves outside the docs root"))
            covered.add(repo)
            continue
        if not (repo_root / ".git").exists():
            skipped.append(Skip("docs", f"repo:{repo}", "not a git clone"))
            continue
        # Covered even when refused: its README must not be fetched remotely
        # either, or a work repo's docs would land in the graph through gh.
        covered.add(repo)
        try:
            refusal = _refuse_work_clone(repo_root, repo)
        except GitError as exc:
            skipped.append(Skip("docs", f"repo:{repo}", f"cannot verify work status ({exc}); refused"))
            continue
        if refusal is not None:
            skipped.append(refusal)
            continue
        for path in local_doc_files(repo_root):
            relpath = str(path.relative_to(repo_root))
            try:
                if path.stat().st_size > MAX_DOC_BYTES:
                    skipped.append(Skip("docs", f"repo:{repo}:{relpath}", "file exceeds 200 KB"))
                    continue
                text = path.read_text(encoding="utf-8", errors="replace")
            except OSError as exc:
                skipped.append(Skip("docs", f"repo:{repo}:{relpath}", f"unreadable: {exc}"))
                continue
            doc_episodes, doc_skips = _doc_episodes(
                repo=repo,
                relpath=relpath,
                text=text,
                valid_at=git_last_commit(repo_root, relpath) or file_timestamp(path) or _now_iso(),
            )
            episodes.extend(doc_episodes)
            skipped.extend(doc_skips)

    for repo_info in list_repos():
        repo = str(repo_info.get("name") or "")
        if not repo or repo in covered:
            continue
        if repos is not None and repo not in repos:
            continue
        if repo_info.get("isArchived") or repo_info.get("isFork"):
            skipped.append(Skip("docs", f"repo:{repo}", "archived or a fork"))
            continue
        text = read_readme(repo)
        if not text or not text.strip():
            skipped.append(Skip("docs", f"repo:{repo}:README.md", "no README"))
            continue
        if len(text.encode("utf-8")) > MAX_DOC_BYTES:
            skipped.append(Skip("docs", f"repo:{repo}:README.md", "README exceeds 200 KB"))
            continue
        doc_episodes, doc_skips = _doc_episodes(repo=repo, relpath="README.md", text=text)
        episodes.extend(doc_episodes)
        skipped.extend(doc_skips)

    return Plan(source="docs", episodes=episodes, skipped=skipped)


def repo_filter(repo_list_path: str | None, repo_args: list[str] | None) -> set[str] | None:
    """Combine `--repo-list` (one name per line) with repeated `--repo`."""
    names = {name.strip() for name in (repo_args or []) if name.strip()}
    if repo_list_path:
        path = Path(repo_list_path).expanduser()
        try:
            for line in path.read_text(encoding="utf-8").splitlines():
                line = line.strip()
                if line and not line.startswith("#"):
                    names.add(line)
        except OSError as exc:
            raise SourceError(f"cannot read repo list {path}: {exc}") from exc
    return names or None
