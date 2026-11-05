#!/usr/bin/env python3
"""Harvest the user's work trail into the memory instance as idempotent episodes.

Sources are the user's commits in work-owner repos (git reflogs), GitHub PRs
(gh) and Jira tickets (acli). Calendar and Granola titles are fetched
interactively by the brain skill, and chat and mail are not sources: no
collector or episode path exists for them. Episode text is a pure function of the source facts, so the memory store's
content-hash identity makes a re-harvest a no-op; per-source cursors only bound
how far back a run looks, and a source that fails keeps its cursor.
"""
import argparse
import contextlib
import fcntl
import json
import os
import re
import socket
import subprocess
import sys
import time as systime
import traceback
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta
from pathlib import Path
from typing import Callable

GIT, GITHUB, JIRA = "git", "github", "jira"
SOURCES = (GIT, GITHUB, JIRA)
# One work-only instance per machine, and standups span repos, so one timeline: `global` is the
# only group every project's search includes.
MEMORY_GROUP = "global"
FIRST_RUN_DAYS = 7
BACKLOG_CAP_DAYS = 14
# Before this, "today" is still yesterday.
ROLLOVER = time(4)
REPO_DEPTH = 3
# Only the user's own commits: merges, pulls, rebases, cherry-picks and `commit (merge)` are
# integration noise (the PR episodes cover what landed), and checkouts and resets are navigation.
GIT_ACTIONS = frozenset({"commit", "commit (initial)", "commit (amend)"})
SUBJECT_CHARS = 200
GIT_LINES_PER_EPISODE = 60
GH_LIMIT = 1000
GH_FIELDS = "url,title,state,isDraft"
GH_ROLES = {"author": "--author=@me", "reviewer": "--reviewed-by=@me", "commenter": "--commenter=@me"}
ROLE_VERBS = {"author": "authored", "reviewer": "reviewed", "commenter": "commented on"}
JIRA_LIMIT = 100
NETWORK_WAIT = timedelta(minutes=2)
# launchd never starts a job that is still running, so no step may hang.
GIT_TIMEOUT = 60
GH_TIMEOUT = 120
ACLI_TIMEOUT = 120
MEMORY_TIMEOUT = 120

CTRL_RE = re.compile(
    r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f‎‏  ‪-‮⁦-⁩]"
)
SECRET_RE = re.compile(
    r"gh[pousr]_[A-Za-z0-9]{20,}"
    r"|github_pat_[A-Za-z0-9_]{20,}"
    r"|xox[abprs]-[A-Za-z0-9-]{10,}"
    r"|AKIA[0-9A-Z]{16}"
    r"|sk-[A-Za-z0-9_-]{20,}"
    r"|[sr]k_(?:live|test)_[A-Za-z0-9]{16,}"
    r"|AIza[0-9A-Za-z_-]{35}"
    r"|glpat-[A-Za-z0-9_-]{20,}"
    r"|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"
    r"|-----BEGIN [A-Z ]+-----"
    r"|ASIA[0-9A-Z]{16}"
    r"|xox[ep]-[A-Za-z0-9-]{10,}|xapp-[A-Za-z0-9-]{10,}"
    r"|ATATT[A-Za-z0-9_=-]{20,}"
    r"|ya29\.[A-Za-z0-9_-]{20,}"
    r"|npm_[A-Za-z0-9]{36}"
    r"|SG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}"
    r"|://[^/\s:@]+:[^/\s@]+@"
    r"|X-Amz-Signature=[0-9a-f]{16,}"
    r"|(?i:(?:client_secret|access_token|refresh_token|id_token|token|secret|password|passwd|pwd|api[_-]?key|sig)=[^\s&\"']{4,})"
    r"|hooks\.slack\.com/services/[A-Za-z0-9/]+"
)


class Refused(Exception):
    pass


class MemoryWriteError(Exception):
    pass


@dataclass(frozen=True)
class Config:
    state_dir: Path
    repo_roots: tuple = ()
    user: str = "the user"
    work_owners: tuple = ()


def clean(text):
    return SECRET_RE.sub("[REDACTED]", CTRL_RE.sub("", str(text))).strip()


def label(text, limit=SUBJECT_CHARS):
    """A one-line, redacted, bounded label."""
    one = " ".join(clean(text).split())
    return one if len(one) <= limit else one[:limit] + "…"


def slug(text):
    """The memory service's group slug; a test pins it to groups.sanitize_slug."""
    cleaned = re.sub(r"[^a-z0-9_-]+", "-", text.lower()).strip("-")
    return (cleaned or "unknown")[:60]


# Local time throughout: `astimezone()` follows the system zone, DST included.


def local(moment):
    return moment.astimezone()


def midnight(day):
    return datetime.combine(day, time()).astimezone()


def work_day(moment):
    return (local(moment) - timedelta(hours=ROLLOVER.hour, minutes=ROLLOVER.minute)).date()


def plan(source, cursors, today):
    """(first day, last day) to pull. The cursor day is pulled again to catch late additions."""
    floor = today - timedelta(days=BACKLOG_CAP_DAYS)
    try:
        start = date.fromisoformat(cursors[source])
    except (KeyError, ValueError, TypeError):
        start = today - timedelta(days=FIRST_RUN_DAYS)
    # Git episodes are one per repo and day, so only finished days are written.
    end = today - timedelta(days=1) if source == GIT else today
    return max(start, floor), end


def git(repo, *args):
    # Scanned checkouts are not all trusted: reads must never run a configured program or reach a network helper.
    config = ["core.hooksPath=/dev/null", "core.fsmonitor=false", "protocol.allow=never", "diff.external="]
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_") or k in ("GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM")}
    env["GIT_NO_LAZY_FETCH"] = "1"
    return subprocess.run(
        ["git", "-C", str(repo), *(a for kv in config for a in ("-c", kv)), *args],
        env=env, capture_output=True, text=True, timeout=GIT_TIMEOUT, check=False,
    ).stdout


def find_repos(roots):
    """Git checkouts under each root (not inside other checkouts), deduped through symlinks."""
    found = set()

    def walk(path, depth):
        if (path / ".git").is_dir():
            found.add(path.resolve())
            return
        if depth == 0:
            return
        with contextlib.suppress(OSError):
            for entry in os.scandir(path):
                if entry.is_dir() and not entry.name.startswith("."):
                    walk(Path(entry.path), depth - 1)

    for root in roots:
        walk(Path(root).expanduser(), REPO_DEPTH)
    return sorted(found)


def worktrees(repo, roots):
    """The repo's worktrees that live under a scan root; a stale or planted entry can point anywhere."""
    out = git(repo, "worktree", "list", "--porcelain", "-z")
    paths = [Path(f[len("worktree "):]) for f in out.split("\0") if f.startswith("worktree ")] or [repo]
    resolved = [Path(r).expanduser().resolve() for r in roots]
    return [p for p in paths if any(p.resolve().is_relative_to(r) for r in resolved)]


def origin_repo(repo):
    """(owner, repo) from the origin remote, or None; credentials in the URL are never kept."""
    url = git(repo, "config", "--get", "remote.origin.url").strip()
    match = re.search(r"[:/]([\w.-]+)/([\w.-]+?)(?:\.git)?/?$", url)
    return match.groups() if match else None


def reflog_rows(lines, start, end):
    rows = []
    for line in lines:
        selector, subject = (line.split("\0") + ["", ""])[:2]
        stamp = re.search(r"@\{(.+)\}", selector)
        if not stamp:
            continue
        moment = local(datetime.fromisoformat(stamp.group(1)))
        head, _, rest = subject.partition(": ")
        # The exact verb: a longer head can carry a ref name someone else chose.
        if head in GIT_ACTIONS and start <= moment < end:
            rows.append((moment, moment.date(), f"{head}: {label(rest)}"))
    return rows


def git_episodes(roots, first, last, user, owners):
    start, end = midnight(first), midnight(last + timedelta(days=1))
    by_day = {}
    for repo in find_repos(roots):
        # Fail closed: a repo with no parseable origin, or a personal one, is never read.
        origin = origin_repo(repo)
        if origin is None or origin[0].lower() not in {o.lower() for o in owners}:
            continue
        name = label("/".join(origin))
        for tree in worktrees(repo, roots):
            out = git(tree, "log", "-g", "--date=iso-strict", "--format=%gd%x00%gs", "HEAD")
            # Only newline frames an entry; splitlines() would also break on separators inside a subject.
            for moment, day, text in reflog_rows(out.split("\n"), start, end):
                by_day.setdefault((name, day), {})[(moment, text)] = None
    episodes = []
    for (name, day), entries in sorted(by_day.items(), key=lambda kv: (kv[0][1], kv[0][0])):
        lines = [f"- {text}" for _, text in sorted(entries)]
        dropped = max(0, len(lines) - GIT_LINES_PER_EPISODE)
        kept = (["- (" + f"{dropped} earlier actions not listed)"] if dropped else []) + lines[dropped:]
        episodes.append(f"Git activity by {user} on {day.isoformat()} in {name}:\n" + "\n".join(kept))
    return episodes


def pr_repo(url):
    match = re.match(r"https://github\.com/([\w.-]+/[\w.-]+)/pull/\d+", url)
    return match.group(1) if match else None


def pr_episodes(results_by_role, user, owners):
    """One episode per work-owner PR and state. Update times stay out of the text so only a real change is new."""
    work = {o.lower() for o in owners}
    merged = {}
    for role, results in results_by_role.items():
        for pr in results:
            url = pr.get("url") or ""
            # Fail closed, like the git source: search scoping is a courtesy, this is the gate.
            if (repo := pr_repo(url)) and repo.split("/")[0].lower() in work:
                merged.setdefault(url, (repo, pr, set()))[2].add(role)
    episodes = []
    for url, (repo, pr, roles) in sorted(merged.items()):
        verbs = [ROLE_VERBS[r] for r in ROLE_VERBS if r in roles]
        joined = " and ".join([", ".join(verbs[:-1])] + verbs[-1:]) if len(verbs) > 1 else verbs[0]
        state = str(pr.get("state") or "unknown").lower() + (", draft" if pr.get("isDraft") else "")
        episodes.append(f'{user} {joined} pull request "{label(pr.get("title") or "")}" in {repo} ({url}); it is {state}.')
    return episodes


def jira_field(item, name):
    fields = item.get("fields") if isinstance(item.get("fields"), dict) else {}
    value = fields.get(name, item.get(name))
    return value.get("name") if isinstance(value, dict) else value


def jira_episodes(output, user):
    items = json.loads(output)
    if not isinstance(items, list):
        raise ValueError("acli did not return a list of work items")
    episodes = []
    for item in items:
        key = item.get("key") if isinstance(item, dict) else None
        if not (isinstance(key, str) and re.fullmatch(r"[A-Z][A-Z0-9]+-\d+", key)):
            continue
        summary, status = (label(jira_field(item, f) or "") for f in ("summary", "status"))
        episodes.append(f'Jira ticket {key} "{summary}" involves {user} and is {status or "of unknown status"}.')
    return sorted(episodes)


def run_gh(args):
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True, timeout=GH_TIMEOUT).stdout


def run_acli(args):
    return subprocess.run(["acli", *args], check=True, capture_output=True, text=True, timeout=ACLI_TIMEOUT).stdout


def memory_writer(binary="memory"):
    def write(text):
        try:
            proc = subprocess.run(
                [binary, "--group", MEMORY_GROUP, "write", "-"],
                input=text, capture_output=True, text=True, timeout=MEMORY_TIMEOUT, check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as err:
            raise MemoryWriteError(str(err)) from err
        if proc.returncode:
            raise MemoryWriteError((proc.stderr or proc.stdout).strip() or f"exit {proc.returncode}")

    return write


@dataclass(frozen=True)
class Tools:
    gh: Callable = run_gh
    acli: Callable = run_acli
    memory: Callable = memory_writer()


def collect_github(first, tools, user, owners):
    span = f"--updated=>={first.isoformat()}"
    # One scoped search per owner: personal PRs are never even fetched. No owners, no search.
    results = {
        role: [
            pr
            for owner in owners
            for pr in json.loads(
                tools.gh(["search", "prs", "--owner", owner, flag, span, "--limit", str(GH_LIMIT), "--json", GH_FIELDS])
            )
        ]
        for role, flag in GH_ROLES.items()
    } if owners else {}
    return pr_episodes(results, user, owners)


def collect_jira(first, tools, user):
    day = first.isoformat()
    jql = (
        f'(assignee = currentUser() OR reporter = currentUser() OR status CHANGED BY currentUser() AFTER "{day}") '
        f'AND updated >= "{day}" ORDER BY updated DESC'
    )
    out = tools.acli(["jira", "workitem", "search", "--jql", jql, "--fields", "key,summary,status", "--limit", str(JIRA_LIMIT), "--json"])
    return jira_episodes(out, user)


def read_json(path, default):
    # A torn or hand-mangled state file must not wedge every later run.
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, ValueError):
        return default
    return value if isinstance(value, type(default)) else default


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp = path.with_suffix(".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(json.dumps(value, indent=2) + "\n")
        f.flush()
        os.fsync(f.fileno())
    tmp.replace(path)


@contextlib.contextmanager
def locked(state_dir):
    state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(state_dir / "lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd)
        raise Refused("another harvest is running") from None
    try:
        yield
    finally:
        os.close(fd)


def detail(err):
    text = err.stderr if isinstance(err, subprocess.CalledProcessError) and err.stderr else err
    return label(str(text))


def harvest(config, now, tools, dry_run=None):
    """Collect every source, write its episodes, advance the cursors of sources that finished.

    `dry_run` is a printer: episodes go to it instead of memory, and no cursor moves.
    Returns (exit code, summary).
    """
    today = work_day(now)
    cursors = read_json(config.state_dir / "cursors.json", {})
    windows = {s: plan(s, cursors, today) for s in SOURCES}
    write = dry_run or tools.memory
    counts, failures, advanced = {}, {}, {}

    collectors = {
        GIT: lambda: git_episodes(config.repo_roots, *windows[GIT], config.user, config.work_owners),
        GITHUB: lambda: collect_github(windows[GITHUB][0], tools, config.user, config.work_owners),
        JIRA: lambda: collect_jira(windows[JIRA][0], tools, config.user),
    }
    ready = {}
    for source, collect in collectors.items():
        try:
            ready[source] = collect()
        except (OSError, ValueError, subprocess.SubprocessError) as err:
            failures[source] = detail(err)

    for source in SOURCES:
        if source not in ready:
            continue
        try:
            for episode in ready[source]:
                write(episode)
        except MemoryWriteError as err:
            return 1, f"memory write failed ({detail(err)}); nothing further advanced"
        counts[source] = len(ready[source])
        advanced[source] = windows[source][1].isoformat()
    if not dry_run and advanced:
        write_json(config.state_dir / "cursors.json", {**cursors, **advanced})

    summary = ", ".join(f"{s} {n}" for s, n in counts.items()) or "nothing"
    problems = "; ".join(f"{s}: {why}" for s, why in failures.items())
    return (1 if failures else 0), f"episodes {summary}" + (f". Held: {problems}" if problems else "")


def notify_macos(text):
    print(text, flush=True)
    # argv, not string interpolation: the text carries source names and error details.
    script = ["-e", "on run argv", "-e", 'display notification (item 1 of argv) with title "Harvest"', "-e", "end run"]
    with contextlib.suppress(OSError):
        subprocess.run(["/usr/bin/osascript", *script, text[:240]], check=False, capture_output=True)


def network_up(wait=NETWORK_WAIT, host=("api.github.com", 443)):
    # A run fired on wake can beat Wi-Fi; harvesting offline would only record failures.
    deadline = systime.monotonic() + wait.total_seconds()
    while True:
        try:
            socket.create_connection(host, timeout=5).close()
            return True
        except OSError:
            left = deadline - systime.monotonic()
            if left <= 0:
                return False
            systime.sleep(min(10, left))


def unattended(config, now, tools, notify=notify_macos, online=network_up):
    if not online():
        notify("Harvest: offline, skipped; the next run catches up.")
        return 1
    try:
        with locked(config.state_dir):
            code, message = harvest(config, now, tools)
    except Refused as err:
        notify(f"Harvest: not started: {err}")
        return 1
    except Exception as err:  # launchd logs go unread
        traceback.print_exc()
        notify(f"Harvest: crashed ({type(err).__name__}: {err}); nothing further advanced.")
        return 1
    notify(f"Harvest: {message}.")
    return code


def env_paths(name):
    return tuple(Path(p).expanduser() for p in os.environ.get(name, "").split(os.pathsep) if p)


def main(argv=None, now=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--state-dir", type=Path, default=Path(os.environ.get("HARVEST_STATE_DIR", "~/.local/state/harvest")))
    parser.add_argument("--repo-root", type=Path, action="append", help="dir to scan for git checkouts (default: $HARVEST_REPO_ROOTS)")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("run", help="harvest every source into memory and notify")
    sub.add_parser("dry-run", help="print the episodes a run would write; write nothing and move no cursor")
    args = parser.parse_args(argv)

    config = Config(
        state_dir=args.state_dir.expanduser(),
        repo_roots=tuple(p.expanduser() for p in args.repo_root) if args.repo_root else env_paths("HARVEST_REPO_ROOTS"),
        user=os.environ.get("HARVEST_USER", "the user"),
        work_owners=tuple(o for o in os.environ.get("HARVEST_WORK_OWNERS", "").split(",") if o),
    )
    tools = Tools(memory=memory_writer(os.environ.get("HARVEST_MEMORY", "memory")))
    now = now or datetime.now().astimezone()
    if args.command == "run":
        return unattended(config, now, tools)
    try:
        with locked(config.state_dir):
            code, message = harvest(config, now, tools, dry_run=lambda text: print(text + "\n"))
    except Refused as err:
        print(f"harvest: {err}", file=sys.stderr)
        return 1
    print(message, file=sys.stderr)
    return code


if __name__ == "__main__":
    sys.exit(main())
