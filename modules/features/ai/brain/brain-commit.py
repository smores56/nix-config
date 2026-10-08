#!/usr/bin/env python3
"""Commit harvested notes to the local brain vault, refusing anything unsafe.

Harvests read untrusted mail, chat, and tickets, so the commit step is code,
not prose: it only ever commits note paths in a remote-less vault, never runs
git hooks, and blocks secret-shaped text before it reaches history.
"""
import argparse
import importlib.util
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

NOTE_DIRS = ("daily/", "wiki/", "til/", "standups/")
NOTE_FILES = ("index.md", "glossary.md", "questions.md", "brag.md")
HUNK_RE = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)")


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
    return path.startswith(NOTE_DIRS) or path in NOTE_FILES


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


def secret_hits(diff):
    """file:line for each added line that looks like a secret (the text itself is never echoed)."""
    hits, current, line_no = [], None, 0
    for line in diff.splitlines():
        if line.startswith("+++ "):
            current = line[6:] if line.startswith("+++ b/") else None
        elif match := HUNK_RE.match(line):
            line_no = int(match.group(1))
        elif line.startswith("+"):
            if current and SECRET_RE.search(line):
                hits.append(f"{current}:{line_no}")
            line_no += 1
    return hits


def commit(vault, message, env=None):
    vault = Path(vault).expanduser().resolve()

    def git(*args, check=True):
        return subprocess.run(
            ["git", "-C", str(vault), "-c", "core.hooksPath=/dev/null", *args],
            env=env,
            check=check,
            capture_output=True,
            text=True,
        )

    if not vault.is_dir():
        return Result("refused", f"{vault} is not a directory")
    toplevel = git("rev-parse", "--show-toplevel", check=False)
    if toplevel.returncode != 0 or Path(toplevel.stdout.strip()).resolve() != vault:
        return Result("refused", f"{vault} is not the root of its own git repo")
    if remotes := git("remote").stdout.split():
        return Result("refused", f"vault has remotes ({', '.join(remotes)}); it must stay local-only")

    paths = changed_paths(git("status", "--porcelain=v1", "-z", "--untracked-files=all").stdout)
    if not paths:
        return Result("nothing")
    if outside := sorted(p for p in set(paths) if not is_note_path(p)):
        return Result(
            "refused",
            "changes outside note paths (commit them yourself if intended): " + ", ".join(outside),
        )

    git("add", "-A", "--", *paths)
    if hits := secret_hits(git("diff", "--cached", "-U0", "--no-color").stdout):
        git("reset", "-q")
        return Result("refused", "secret-shaped text at " + ", ".join(hits))
    git("commit", "-q", "--no-verify", "-m", message)
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
