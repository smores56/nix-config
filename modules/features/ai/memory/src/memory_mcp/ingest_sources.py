"""Corpus adapters for `memory ingest`: sdlc issues, personal notes, repo docs.

Each adapter is pure over an injected fetcher (`run_gh`, a filesystem walk), so
the mapping and chunking are testable without the network. Every episode
carries the group it belongs to and a stable `source_id`; the runner adds the
content hash and provenance headers.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Iterable

from .chunking import document_title, episode_content, sections_for, source_ids
from .groups import GroupRefused, owner_is_work, sanitize_slug, validate_group

SDLC_REPO = "smores56/sdlc"
SDLC_GROUP = "smores56--sdlc"
NOTES_GROUP = "global"
PERSONAL_OWNER = "smores56"
MAX_DOC_BYTES = 200_000
COMMENT_MIN_CHARS = 20
GH_TIMEOUT_SECONDS = 120

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
    origin: str = ""


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

    def limited(self, limit: int | None) -> Plan:
        if limit is None or limit <= 0 or len(self.episodes) <= limit:
            return self
        return Plan(source=self.source, episodes=self.episodes[:limit], skipped=self.skipped)


def run_gh(args: Iterable[str]) -> str:
    try:
        result = subprocess.run(
            ["gh", *args],
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
        raise SourceError(f"gh {args[0]} failed: {message[:300]}")
    return result.stdout


def gh_json(args: Iterable[str]) -> object:
    try:
        return json.loads(run_gh(args))
    except json.JSONDecodeError as exc:
        raise SourceError(f"gh returned invalid JSON: {exc}") from exc


def fetch_issues(runner: Callable[[Iterable[str]], str] = run_gh) -> list[dict[str, object]]:
    payload = runner(
        ["issue", "list", "--repo", SDLC_REPO, "--state", "all", "--limit", "1000", "--json", ISSUE_FIELDS]
    )
    try:
        issues = json.loads(payload) if isinstance(payload, str) else payload
    except json.JSONDecodeError as exc:
        raise SourceError(f"gh issue list returned invalid JSON: {exc}") from exc
    if not isinstance(issues, list):
        raise SourceError("gh issue list did not return a list")
    return [issue for issue in issues if isinstance(issue, dict)]


def issue_number(issue: dict[str, object]) -> int:
    return int(issue["number"])  # type: ignore[arg-type]


def _labels(issue: dict[str, object]) -> list[str]:
    labels = issue.get("labels")
    if not isinstance(labels, list):
        return []
    return [str(label.get("name", "")) for label in labels if isinstance(label, dict)]


def repo_label(issue: dict[str, object]) -> str | None:
    for label in _labels(issue):
        match = REPO_LABEL.match(label)
        if match:
            return match.group(1).strip()
    return None


def group_for_repo_label(repo: str) -> str | None:
    """Map a `repo:` label to a personal group, refusing employer-owned repos."""
    candidate = repo.strip()
    if "--" in candidate:
        owner, name = candidate.split("--", 1)
    else:
        owner, name = PERSONAL_OWNER, candidate
    if not name or owner_is_work(owner) or owner_is_work(name):
        return None
    try:
        return validate_group(f"{owner}--{sanitize_slug(name)}")
    except GroupRefused:
        return None


def parent_number(issue: dict[str, object]) -> int | None:
    match = PART_OF.search(str(issue.get("body") or ""))
    return int(match.group(1)) if match else None


def resolve_group(
    number: int, issues: dict[int, dict[str, object]], seen: frozenset[int] = frozenset()
) -> tuple[str, str]:
    """Follow `Part of #N` to the nearest feature with a repo label."""
    issue = issues.get(number)
    if issue is None:
        return SDLC_GROUP, "parent not in the issue list"
    label = repo_label(issue)
    if label:
        group = group_for_repo_label(label)
        if group is None:
            return "", f"repo label {label!r} belongs to the employer"
        return group, f"repo:{label}"
    parent = parent_number(issue)
    if parent is None or parent in seen:
        return SDLC_GROUP, "no repo label"
    return resolve_group(parent, issues, seen | {number})


def _comment_id(comment: dict[str, object], index: int) -> str:
    url = str(comment.get("url") or "")
    match = COMMENT_ID.search(url)
    if match:
        return match.group(1)
    raw = re.sub(r"[^A-Za-z0-9_-]+", "", str(comment.get("id") or ""))
    return raw or str(index + 1)


def _issue_episodes(
    issue: dict[str, object], group: str
) -> tuple[list[Episode], list[Skip]]:
    number = issue_number(issue)
    title = str(issue.get("title") or f"issue {number}")
    ref = f"{SDLC_REPO}#{number}"
    tags = ("sdlc", f"issue-{number}")
    episodes: list[Episode] = []
    skipped: list[Skip] = []

    body = str(issue.get("body") or "").strip()
    sections = sections_for(body)
    if not sections:
        skipped.append(Skip("sdlc", f"issue-{number}#body", "body is empty or boilerplate"))
    else:
        for section, source_id in zip(sections, source_ids(f"issue-{number}", sections)):
            episodes.append(
                Episode(
                    source="sdlc",
                    source_id=source_id,
                    group=group,
                    content=episode_content(ref, title, section.label, section.body),
                    tags=tags,
                    origin=ref,
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
            url = str(comment.get("url") or "")
            base = f"issue-{number}#comment-{_comment_id(comment, index)}"
            comment_sections = sections_for(text, min_chars=1)
            for section, source_id in zip(
                comment_sections, source_ids(base, comment_sections)
            ):
                label = f"comment by {author} on {created[:10]}"
                if section.label:
                    label += f" — {section.label}"
                episodes.append(
                    Episode(
                        source="sdlc",
                        source_id=source_id,
                        group=group,
                        content=episode_content(f"{ref} ({url})" if url else ref, title, label, section.body),
                        tags=tags,
                        origin=ref,
                    )
                )
    return episodes, skipped


def sdlc_plan(issues: list[dict[str, object]]) -> Plan:
    ordered = sorted(issues, key=issue_number)
    by_number = {issue_number(issue): issue for issue in ordered}
    episodes: list[Episode] = []
    skipped: list[Skip] = []
    for issue in ordered:
        number = issue_number(issue)
        group, reason = resolve_group(number, by_number)
        if not group:
            skipped.append(Skip("sdlc", f"issue-{number}", reason))
            continue
        issue_episodes, issue_skips = _issue_episodes(issue, group)
        episodes.extend(issue_episodes)
        skipped.extend(issue_skips)
    return Plan(source="sdlc", episodes=episodes, skipped=skipped)


def notes_plan(notes_dir: str) -> Plan:
    root = Path(notes_dir).expanduser()
    if not root.is_dir():
        raise SourceError(f"notes directory not found: {root}")
    episodes: list[Episode] = []
    skipped: list[Skip] = []
    for path in sorted(root.glob("*.md")):
        if not path.is_file() or path.stat().st_size > MAX_DOC_BYTES:
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        title = document_title(text, path.stem)
        ref = f"note:{path.name}"
        sections = sections_for(text)
        if not sections:
            skipped.append(Skip("notes", f"{ref}#body", "file is empty or boilerplate"))
            continue
        for section, source_id in zip(sections, source_ids(ref, sections)):
            episodes.append(
                Episode(
                    source="notes",
                    source_id=source_id,
                    group=NOTES_GROUP,
                    content=episode_content(ref, title, section.label, section.body),
                    tags=("notes",),
                    origin=str(path),
                )
            )
    return Plan(source="notes", episodes=episodes, skipped=skipped)


def local_doc_files(repo_root: Path) -> list[Path]:
    """README, AGENTS, and docs/**/*.md, skipping generated and vendor trees."""
    files: list[Path] = []
    for name in ("README.md", "AGENTS.md"):
        candidate = repo_root / name
        if candidate.is_file():
            files.append(candidate)
    docs = repo_root / "docs"
    if docs.is_dir():
        for current, dirs, names in os.walk(docs):
            dirs[:] = sorted(
                directory
                for directory in dirs
                if directory not in SKIP_DIRS and not directory.startswith("result-")
            )
            for name in sorted(names):
                if name.endswith(".md"):
                    files.append(Path(current) / name)
    return files


def _doc_episodes(*, repo: str, relpath: str, text: str, source: str = "docs") -> tuple[list[Episode], list[Skip]]:
    group = validate_group(f"{PERSONAL_OWNER}--{sanitize_slug(repo)}")
    title = document_title(text, Path(relpath).name)
    ref = f"{PERSONAL_OWNER}/{repo}/{relpath}"
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
                origin=ref,
            )
        )
    return episodes, skipped


def repo_readme(repo: str) -> str | None:
    try:
        return run_gh(["api", f"repos/{PERSONAL_OWNER}/{repo}/readme", "-H", "Accept: application/vnd.github.raw"])
    except SourceError:
        return None


def personal_repos() -> list[dict[str, object]]:
    payload = gh_json(
        ["repo", "list", PERSONAL_OWNER, "--limit", "200", "--json", "name,isArchived,isFork,description"]
    )
    if not isinstance(payload, list):
        raise SourceError("gh repo list did not return a list")
    return [repo for repo in payload if isinstance(repo, dict)]


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

    for repo_root in sorted(path for path in root.iterdir() if path.is_dir()):
        repo = repo_root.name
        if repos is not None and repo not in repos:
            continue
        if not (repo_root / ".git").exists():
            skipped.append(Skip("docs", f"repo:{repo}", "not a git clone"))
            continue
        covered.add(repo)
        for path in local_doc_files(repo_root):
            try:
                if path.stat().st_size > MAX_DOC_BYTES:
                    skipped.append(Skip("docs", f"repo:{repo}:{path.relative_to(repo_root)}", "file exceeds 200 KB"))
                    continue
                text = path.read_text(encoding="utf-8", errors="replace")
            except OSError as exc:
                skipped.append(Skip("docs", f"repo:{repo}:{path.relative_to(repo_root)}", f"unreadable: {exc}"))
                continue
            relpath = str(path.relative_to(repo_root))
            doc_episodes, doc_skips = _doc_episodes(repo=repo, relpath=relpath, text=text)
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
