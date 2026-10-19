#!/usr/bin/env python3
"""Commit harvested notes to the local brain vault, refusing anything unsafe.

Harvests read untrusted mail, chat, and tickets, so the commit step is code,
not prose: it only commits markdown note paths in a remote-less vault, runs no
git hooks, filters, fsmonitor, or signing programs, and before anything reaches
history it blocks secret-shaped text, assistant instruction files, embeds and
HTML, and links to hosts outside the vault's `## Link hosts`. While a harvest
run holds its claim, only that run may commit.
"""
import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path

NOTE_DIRS = ("daily/", "wiki/", "til/", "standups/")
NOTE_FILES = ("index.md", "glossary.md", "questions.md", "brag.md")
# Assistants load these as trusted instructions from whatever directory they read.
INSTRUCTION_FILES = frozenset({"CLAUDE.md", "CLAUDE.local.md", "AGENTS.md", "GEMINI.md"})
# Anything a renderer fetches on preview leaks whatever its URL carries. Fetching needs an
# image, an attribute, a style, or an escaped URL; bare `<word>` in prose stays allowed.
EMBED_RE = re.compile(
    r"!\["
    r"|</?(?:script|style|iframe)\b"
    r"|<[A-Za-z][\w-]*\s+[^>]*="
    r"|\burl\s*\("
    r"|&#"
    r"|@import",
    re.I,
)
# Every link target: markdown `](...)` and reference definitions take any scheme; bare text
# only counts as a link when it is http(s), so prose like "data: x" or "file:line" passes.
MD_TARGET_RE = re.compile(r"\]\(\s*<?([^)\s>]+)|^\s*\[[^\]]+\]:\s*<?(\S+?)>?\s*$")
BARE_URL_RE = re.compile(r"(?<![\w/])https?:[^\s)\]>\"']*", re.I)
HTTP_RE = re.compile(r"https?://([A-Za-z0-9.-]+|\[[0-9a-fA-F:]+\])(?::\d+)?(?=[/?#]|$)", re.I)
LOOPBACK = frozenset({"localhost", "127.0.0.1", "[::1]"})
# Matches brain-run's claim staleness: a dead run's claim must not block commits forever.
CLAIM_STALE_AFTER = timedelta(hours=3)
# Inherited repo-selection variables would point git at some other repo's index.
REPO_ENV = ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_COMMON_DIR")
# Neutralize every config knob that makes git run a program during status/add/commit.
SAFE_CONFIG = (
    "core.hooksPath=/dev/null",
    "core.fsmonitor=false",
    "core.attributesFile=/dev/null",
    "diff.external=",
    # A global ignore list would hide planted note-path files from every check below.
    "core.excludesFile=/dev/null",
    # Signing runs gpg.program / gpg.ssh.program / gpg.x509.program, all settable from .git/config.
    "commit.gpgSign=false",
    "gpg.program=false",
    "gpg.ssh.program=false",
    "gpg.x509.program=false",
)


def _secret_re():
    # One definition of secret shapes, shared with the digest's redaction.
    path = Path(__file__).with_name("brain-digest.py")
    spec = importlib.util.spec_from_file_location("brain_digest", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.SECRET_RE


SECRET_RE = _secret_re()


@dataclass(frozen=True)
class Result:
    status: str  # "committed", "nothing", or "refused"
    detail: str = ""


def is_note_path(path):
    if path in NOTE_FILES:
        return True
    # Markdown only, no dotfiles: a .gitattributes or script under a note dir could
    # change how git treats the notes.
    parts = path.split("/")
    return (
        path.startswith(NOTE_DIRS)
        and path.endswith(".md")
        and not any(p.startswith(".") for p in parts)
        and parts[-1] not in INSTRUCTION_FILES
    )


def changed_paths(porcelain):
    """Paths from `git status --porcelain=v1 -z`; renames contribute both sides."""
    fields = porcelain.split("\0")
    paths, i = [], 0
    while i < len(fields) and fields[i]:
        entry = fields[i]
        paths.append(entry[3:])
        if entry[0] in "RC":
            i += 1
            paths.append(fields[i])
        i += 1
    return paths


def is_linked(vault, path):
    # A symlinked note (or note dir) lets writes escape the vault.
    target = vault / path
    return any(p.is_symlink() for p in [target, *target.parents] if p != vault and vault in p.parents)


def section(markdown, heading, level=2):
    """Body of a `##`-level section of the vault CLAUDE.md, or None; shared with brain-run."""
    marks = "#" * level
    found = re.search(
        rf"^{marks} {re.escape(heading)}[ \t]*\n(.*?)(?=^#{{1,{level}}} |\Z)", markdown, re.MULTILINE | re.DOTALL
    )
    return found.group(1) if found else None


def link_hosts(config_text):
    """Hosts under `## Link hosts`, the first word of each line; None when the section is absent."""
    body = section(config_text, "Link hosts")
    if body is None:
        return None
    words = (line.split()[0].lower() for line in body.splitlines() if line.split())
    return frozenset(w for w in words if re.fullmatch(r"[a-z0-9.-]+", w))


def target_problem(target, hosts):
    """Why a link target is not allowed, or None. Only relative paths and http(s) to a listed host pass."""
    if target.startswith("//") or "\\" in target:
        return "scheme-relative or backslashed link"
    scheme = re.match(r"([A-Za-z][\w+.-]*):", target)
    if not scheme:
        return None
    if scheme.group(1).lower() not in ("http", "https"):
        return f"{scheme.group(1).lower()}: link"
    found = HTTP_RE.match(target)
    if not found:
        return "malformed or credentialed URL"
    host = found.group(1).lower()
    return None if host in hosts or host in LOOPBACK else f"link to {host}"


def content_hits(name, content, hosts):
    """name:line for embeds and HTML, and for links off the configured hosts."""
    lines = content.decode("utf-8", errors="replace").splitlines()
    hits = []
    for n, line in enumerate(lines, 1):
        if EMBED_RE.search(line):
            hits.append(f"{name}:{n} (image or HTML)")
        targets = [t for pair in MD_TARGET_RE.findall(line) for t in pair if t] + BARE_URL_RE.findall(line)
        hits += [f"{name}:{n} ({p})" for p in {target_problem(t, hosts) for t in targets} if p]
    return hits


def claim_refusal(state_dir, run):
    # Without this, an attended commit could sweep up a running harvest's half-written notes.
    try:
        active = json.loads((state_dir / "active.json").read_text(encoding="utf-8"))
        started = datetime.fromisoformat(active["started"])
    except (OSError, ValueError, KeyError, TypeError):
        return None
    if datetime.now().astimezone() - started >= CLAIM_STALE_AFTER or active.get("nonce") == run:
        return None
    return f"harvest run {active.get('nonce')} is in progress; commit after it finishes"


def default_state_dir():
    return Path(os.environ.get("BRAIN_STATE_DIR", "~/.local/state/brain")).expanduser()


def secret_hits(name, content):
    """name:line for each line that looks like a secret (the text itself is never echoed)."""
    lines = content.decode("utf-8", errors="replace").splitlines()
    return [f"{name}:{n}" for n, line in enumerate(lines, 1) if SECRET_RE.search(line)]


def commit(vault, message, env=None, state_dir=None, run=None):
    vault = Path(vault).expanduser().resolve()
    env = {k: v for k, v in (os.environ if env is None else env).items() if k not in REPO_ENV}
    config = [arg for kv in SAFE_CONFIG for arg in ("-c", kv)]

    def git(*args, check=True, text=True):
        return subprocess.run(
            ["git", "-C", str(vault), *config, *args], env=env, check=check, capture_output=True, text=text
        )

    if not vault.is_dir():
        return Result("refused", f"{vault} is not a directory")
    toplevel = git("rev-parse", "--show-toplevel", check=False)
    if toplevel.returncode != 0 or Path(toplevel.stdout.strip()).resolve() != vault:
        return Result("refused", f"{vault} is not the root of its own git repo")
    if remotes := git("remote").stdout.split():
        return Result("refused", f"vault has remotes ({', '.join(remotes)}); it must stay local-only")
    if filters := git("config", "--get-regexp", r"^filter\.", check=False).stdout.split("\n")[0]:
        return Result("refused", f"vault config defines filter drivers ({filters.split()[0]}); remove them")
    if busy := claim_refusal(state_dir or default_state_dir(), run):
        return Result("refused", busy)

    paths = changed_paths(git("status", "--porcelain=v1", "-z", "--untracked-files=all").stdout)
    if not paths:
        return Result("nothing")
    if outside := sorted(p for p in set(paths) if not is_note_path(p)):
        return Result(
            "refused",
            "changes outside note paths (commit them yourself if intended): " + ", ".join(outside),
        )
    if linked := sorted(p for p in set(paths) if is_linked(vault, p)):
        return Result("refused", "symlinked note paths: " + ", ".join(linked))

    try:
        # Every change is a note path (checked above), so staging everything stages only notes.
        git("add", "-A")
        staged = git("diff", "--cached", "--name-only", "-z", "--no-renames", "--diff-filter=d").stdout
        # Scan the staged blobs themselves: diff output can be reshaped by config and attributes.
        hits = [
            hit
            for name in filter(None, staged.split("\0"))
            for hit in secret_hits(name, git("cat-file", "blob", f":{name}", text=False).stdout)
        ]
        if hits:
            git("reset", "-q")
            return Result("refused", "secret-shaped text at " + ", ".join(hits))
        # The committed config, not the working copy: a harvest can't widen its own link hosts.
        hosts = link_hosts(git("show", "HEAD:CLAUDE.md", check=False).stdout)
        if hosts is None:
            git("reset", "-q")
            return Result("refused", "the committed vault CLAUDE.md has no `## Link hosts` section")
        bad = [
            hit
            for name in filter(None, staged.split("\0"))
            for hit in content_hits(name, git("cat-file", "blob", f":{name}", text=False).stdout, hosts)
        ]
        if bad:
            git("reset", "-q")
            return Result("refused", "disallowed content at " + ", ".join(bad))
        git("commit", "-q", "--no-verify", "-m", message)
    except subprocess.CalledProcessError as err:
        git("reset", "-q", check=False)
        reason = (err.stderr or "").strip().splitlines()
        return Result("refused", f"git {err.cmd[len(config) + 3]} failed: {reason[0] if reason else err.returncode}")
    return Result("committed")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("-m", "--message", required=True)
    parser.add_argument("--vault", default=os.environ.get("BRAIN_DIR", "~/brain"))
    parser.add_argument("--run", help="the claimed harvest run committing (from `brain-run begin`)")
    args = parser.parse_args(argv)

    result = commit(args.vault, args.message, run=args.run)
    print(f"brain-commit: {result.status}" + (f": {result.detail}" if result.detail else ""))
    return 1 if result.status == "refused" else 0


if __name__ == "__main__":
    sys.exit(main())
