#!/usr/bin/env python3
"""Commit harvested notes to the local brain vault, refusing anything unsafe.

Harvests read untrusted mail, chat, and tickets, so the commit step is code,
not prose: it only commits markdown note paths in a remote-less vault, runs no
git hooks, filters, or fsmonitor, and blocks secret-shaped text before it
reaches history.
"""
import argparse
import importlib.util
import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

NOTE_DIRS = ("daily/", "wiki/", "til/", "standups/")
NOTE_FILES = ("index.md", "glossary.md", "questions.md", "brag.md")
# Inherited repo-selection variables would point git at some other repo's index.
REPO_ENV = ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_COMMON_DIR")
# Neutralize every config knob that makes git run a program during status/add/commit.
SAFE_CONFIG = (
    "core.hooksPath=/dev/null",
    "core.fsmonitor=false",
    "core.attributesFile=/dev/null",
    "diff.external=",
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
    return path.startswith(NOTE_DIRS) and path.endswith(".md") and not any(p.startswith(".") for p in parts)


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


def secret_hits(name, content):
    """name:line for each line that looks like a secret (the text itself is never echoed)."""
    lines = content.decode("utf-8", errors="replace").splitlines()
    return [f"{name}:{n}" for n, line in enumerate(lines, 1) if SECRET_RE.search(line)]


def commit(vault, message, env=None):
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
    args = parser.parse_args(argv)

    result = commit(args.vault, args.message)
    print(f"brain-commit: {result.status}" + (f": {result.detail}" if result.detail else ""))
    return 1 if result.status == "refused" else 0


if __name__ == "__main__":
    sys.exit(main())
