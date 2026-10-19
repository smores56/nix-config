#!/usr/bin/env python3
"""Track how far each brain source has been harvested, and collect the local ones deterministically.

A harvest rebuilds whole daily notes, so cursors pick which days to rebuild:
every day from the earliest source cursor through today. A source's cursor only
moves once the vault holds that run's notes committed, so a source that failed
is re-pulled next run. `begin` claims a run and records its start, `collect`
emits local rows, and `finish` advances the sources the run completed. The
model never picks the timestamps it advances to.
"""
import argparse
import contextlib
import fcntl
import importlib.util
import json
import os
import re
import secrets
import subprocess
import sys
from dataclasses import asdict, dataclass, field
from datetime import date, datetime, time, timedelta
from pathlib import Path

ALWAYS_SOURCES = ("sessions", "git")
# Vault CLAUDE.md `### <heading>` under `## Sources` → source name; unconfigured sources are never waited on.
CONFIGURED_SOURCES = {
    "Code host": "github",
    "Chat": "chat",
    "Mail": "mail",
    "Calendar": "calendar",
    "Issue tracker": "tracker",
}
SOURCES = ALWAYS_SOURCES + tuple(CONFIGURED_SOURCES.values())
LOCAL_SOURCES = ("sessions", "git", "github")
# A long backlog in one run would blow the turn budget and never advance anything.
DAY_CAP = 5
# Before this, "today" is still yesterday: the skill's late-night rule.
ROLLOVER = time(4)
# Longer than the headless run's wall-clock timeout, so only a dead claim is ever taken over.
STALE_AFTER = timedelta(hours=3)
# Deep enough for <root>/<host>/<owner>/<repo>.
REPO_DEPTH = 3
# Reflog actions that are work; checkouts and resets are navigation.
GIT_ACTIONS = ("commit", "merge", "pull", "rebase (finish)", "cherry-pick", "revert")
# Commit subjects and PR titles are one-line labels, not content.
SUBJECT_CHARS = 200
# Rows are prompt input; a checkout full of automated commits must not flood the run.
GIT_ROW_CAP = 500
GH_LIMIT = 1000
GH_FIELDS = "url,title,state,isDraft,updatedAt,closedAt"
GH_ROLES = {"author": "--author=@me", "reviewer": "--reviewed-by=@me", "commenter": "--commenter=@me"}
TICKET_KEY_RE = re.compile(r"^[A-Z][A-Z0-9]{1,9}$")


def _load(name):
    path = Path(__file__).with_name(f"{name}.py")
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


DIGEST = _load("brain-digest")
COMMIT = _load("brain-commit")


class Refused(Exception):
    pass


@dataclass(frozen=True)
class Config:
    vault: Path
    state_dir: Path
    repo_roots: tuple[Path, ...] = ()
    transcripts: Path = field(default_factory=DIGEST.default_root)

    @property
    def run_dir(self):
        # Headless runs work here, so their own transcripts are recognizable and never re-ingested.
        return self.state_dir / "run"


@dataclass(frozen=True)
class Run:
    nonce: str
    started: str  # aware ISO
    head0: str  # "" for a vault with no commits yet
    cursors_read: dict
    sources: tuple[str, ...]
    days: tuple[str, ...]
    advance_to: str  # aware ISO: `started`, or the end of the backlog chunk when capped
    truncated: bool


# Pure core (local time throughout: `astimezone()` follows the system zone, DST included)


def local(moment):
    return moment.astimezone()


def midnight(day):
    return DIGEST.day_start(day, None)


def work_day(moment):
    return (local(moment) - timedelta(hours=ROLLOVER.hour, minutes=ROLLOVER.minute)).date()


def plan_days(cursors, sources, default_day, today, cap=DAY_CAP):
    """Days to rebuild, and the cursor target for the run's completed sources (None: the run's start)."""
    starts = [local(datetime.fromisoformat(cursors[s])).date() if s in cursors else default_day for s in sources]
    start = min(min(starts), today)
    days = [start + timedelta(days=i) for i in range((today - start).days + 1)]
    if len(days) <= cap:
        return days, None
    # Today is always rebuilt, so one source that stays down can't freeze the vault in the past.
    backlog = days[: cap - 1]
    return backlog + [today], midnight(backlog[-1] + timedelta(days=1))


def advance(cursors_now, cursors_read, complete, target):
    """Move each completed source forward to target, unless another run moved it since this one read it."""

    def moved(source):
        current = cursors_now.get(source)
        unchanged = current == cursors_read.get(source)
        forward = current is None or datetime.fromisoformat(current) < datetime.fromisoformat(target)
        return unchanged and forward

    return {**cursors_now, **{s: target for s in complete if moved(s)}}


def window(days, until):
    """[first day's midnight, min(until, midnight after the last day))."""
    first, last = (date.fromisoformat(d) for d in (days[0], days[-1]))
    return midnight(first), min(local(datetime.fromisoformat(until)), midnight(last + timedelta(days=1)))


def section(markdown, heading, level=2):
    marks = "#" * level
    found = re.search(
        rf"^{marks} {re.escape(heading)}[ \t]*\n(.*?)(?=^#{{1,{level}}} |\Z)", markdown, re.MULTILINE | re.DOTALL
    )
    return found.group(1) if found else None


def ticket_prefixes(vault_config):
    """Keys listed one per line under the vault CLAUDE.md's `## Ticket prefixes`."""
    lines = (section(vault_config, "Ticket prefixes") or "").splitlines()
    return tuple(line.strip() for line in lines if TICKET_KEY_RE.match(line.strip()))


def configured_sources(vault_config):
    """Sessions and git always; the rest only when the vault's `## Sources` has their subsection."""
    sources = section(vault_config, "Sources")
    if sources is None:
        return SOURCES
    headings = set(re.findall(r"^### (.+?)[ \t]*$", sources, re.MULTILINE))
    return ALWAYS_SOURCES + tuple(name for heading, name in CONFIGURED_SOURCES.items() if heading in headings)


def reflog_rows(repo, lines, start, end):
    rows = []
    for line in lines:
        sha, selector, subject = (line.split("\0") + ["", ""])[:3]
        stamp = re.search(r"@\{(.+)\}", selector)
        if not stamp:
            continue
        moment = local(datetime.fromisoformat(stamp.group(1)))
        head, _, rest = subject.partition(": ")
        # Only the verb: the rest of the head can carry a ref name someone else chose.
        action = next((a for a in GIT_ACTIONS if head.startswith(a)), None)
        if not (start <= moment < end) or action is None:
            continue
        rows.append(
            {
                "source": "git",
                "day": moment.date().isoformat(),
                "repo": str(repo),
                "time": moment.isoformat(),
                "action": action,
                "subject": DIGEST.truncate(DIGEST.clean(rest), SUBJECT_CHARS),
                "sha": sha[:12],
            }
        )
    return rows


def pr_rows(results_by_role):
    """Merge `gh search prs` results by URL, keeping every role the user had on the PR."""
    merged = {}
    for role, results in results_by_role.items():
        for pr in results:
            row = merged.setdefault(
                pr["url"],
                {
                    "source": "github",
                    "url": pr["url"],
                    "title": DIGEST.truncate(DIGEST.clean(pr.get("title") or ""), SUBJECT_CHARS),
                    "state": pr.get("state"),
                    "draft": pr.get("isDraft"),
                    "updated": pr.get("updatedAt"),
                    "closed": pr.get("closedAt"),
                    "roles": [],
                },
            )
            row["roles"].append(role)
    return sorted(merged.values(), key=lambda r: r["updated"] or "")


# Effects


# Scanned checkouts are not all trusted: reads must never reach a network helper.
READ_CONFIG = COMMIT.SAFE_CONFIG + ("protocol.allow=never",)


def git(repo, *args, check=True):
    config = [arg for kv in READ_CONFIG for arg in ("-c", kv)]
    env = {k: v for k, v in os.environ.items() if k not in COMMIT.REPO_ENV} | {"GIT_NO_LAZY_FETCH": "1"}
    return subprocess.run(["git", "-C", str(repo), *config, *args], env=env, check=check, capture_output=True, text=True)


def read_json(path, default):
    # A torn or hand-mangled state file must not wedge every later run.
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, ValueError):
        return default
    return value if isinstance(value, type(default)) or default is None else default


def write_json(path, value):
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
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def vault_config(config):
    path = config.vault / "CLAUDE.md"
    return path.read_text(encoding="utf-8") if path.is_file() else ""


def vault_dirty(vault):
    # `git status` re-hashes changed files through any filter driver; brain-commit refuses those too.
    if filters := git(vault, "config", "--get-regexp", r"^filter\.", check=False).stdout.split():
        raise Refused(f"vault config defines filter drivers ({filters[0]}); remove them")
    return COMMIT.changed_paths(git(vault, "status", "--porcelain=v1", "-z", "--untracked-files=all").stdout)


def vault_head(vault):
    head = git(vault, "rev-parse", "--verify", "-q", "HEAD", check=False)
    return head.stdout.strip() if head.returncode == 0 else ""


def newest_daily(vault):
    days = sorted(p.stem for p in (vault / "daily").glob("*.md") if re.fullmatch(r"\d{4}-\d{2}-\d{2}", p.stem))
    return date.fromisoformat(days[-1]) if days else None


def load_run(record):
    return Run(**{**record, "days": tuple(record["days"]), "sources": tuple(record["sources"])})


def begin(config, now):
    with locked(config.state_dir):
        active = read_json(config.state_dir / "active.json", None)
        if active and now - datetime.fromisoformat(active["started"]) < STALE_AFTER:
            raise Refused(f"run {active['nonce']} started {active['started']} is still in progress")
        if dirty := vault_dirty(config.vault):
            raise Refused("vault has uncommitted changes: " + ", ".join(sorted(set(dirty))))
        cursors = read_json(config.state_dir / "cursors.json", {})
        sources = configured_sources(vault_config(config))
        today = work_day(now)
        days, capped_at = plan_days(cursors, sources, newest_daily(config.vault) or today, today)
        run = Run(
            nonce=secrets.token_hex(8),
            started=local(now).isoformat(),
            head0=vault_head(config.vault),
            cursors_read=cursors,
            sources=sources,
            days=tuple(d.isoformat() for d in days),
            advance_to=(capped_at or local(now)).isoformat(),
            truncated=capped_at is not None,
        )
        write_json(config.state_dir / "active.json", asdict(run))
        return run


def active_run(config, nonce):
    active = read_json(config.state_dir / "active.json", None)
    if not active or active.get("nonce") != nonce:
        raise Refused(f"run {nonce} is not the active run")
    return load_run(active)


def now_or(clock):
    return local(clock() if clock else datetime.now())


def finish(config, nonce, complete, clock=None):
    """Release the run; advance `complete` sources only if the vault's changes are all committed on top of its start."""
    with locked(config.state_dir):
        run = active_run(config, nonce)
        if unknown := sorted(set(complete) - set(run.sources)):
            raise Refused("not sources of this run: " + ", ".join(unknown))
        (config.state_dir / "active.json").unlink()
        if dirty := vault_dirty(config.vault):
            raise Refused("vault has uncommitted changes, nothing advanced: " + ", ".join(sorted(set(dirty))))
        head = vault_head(config.vault)
        if run.head0 and git(config.vault, "merge-base", "--is-ancestor", run.head0, head or "HEAD", check=False).returncode:
            raise Refused("vault history no longer contains the run's starting commit, nothing advanced")
        # A run that committed nothing proves nothing; its days are simply rebuilt next time.
        committed = head and head != run.head0
        target = min(datetime.fromisoformat(run.advance_to), now_or(clock)).isoformat()
        now = read_json(config.state_dir / "cursors.json", {})
        updated = advance(now, run.cursors_read, complete if committed else [], target)
        write_json(config.state_dir / "cursors.json", updated)
        moved = [s for s in run.sources if updated.get(s) != now.get(s)]
        return {"advanced": moved, "held": [s for s in run.sources if s not in moved]}


def find_repos(roots):
    """Git checkouts under each root (not inside other checkouts), deduped through symlinks."""
    found = {}

    def walk(path, depth):
        if (path / ".git").is_dir():
            found.setdefault(path.resolve(), path)
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
    out = git(repo, "worktree", "list", "--porcelain", "-z", check=False).stdout
    paths = [Path(f[len("worktree ") :]) for f in out.split("\0") if f.startswith("worktree ")] or [repo]
    resolved = [Path(r).expanduser().resolve() for r in roots]
    return [p for p in paths if any(p.resolve().is_relative_to(r) for r in resolved)]


def collect_git(config, days, until):
    start, end = window(days, until)
    rows = []
    for repo in find_repos(config.repo_roots):
        for tree in worktrees(repo, config.repo_roots):
            out = git(tree, "log", "-g", "--date=iso-strict", "--format=%H%x00%gd%x00%gs", "HEAD", check=False).stdout
            # Only newline frames an entry; splitlines() would also break on separators inside a subject.
            rows += reflog_rows(tree, out.split("\n"), start, end)
    rows.sort(key=lambda r: datetime.fromisoformat(r["time"]))
    if len(rows) <= GIT_ROW_CAP:
        return rows
    return rows[:GIT_ROW_CAP] + [{"source": "git", "truncated": len(rows) - GIT_ROW_CAP}]


def collect_github(days, until, gh):
    start, end = window(days, until)
    span = f"--updated={start.isoformat(timespec='seconds')}..{end.isoformat(timespec='seconds')}"
    results = {
        role: json.loads(gh(["search", "prs", flag, span, "--limit", str(GH_LIMIT), "--json", GH_FIELDS]))
        for role, flag in GH_ROLES.items()
    }
    return pr_rows(results)


def run_gh(args):
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout


def collect_sessions(config, days):
    opts = DIGEST.Options(
        ticket_prefixes=ticket_prefixes(vault_config(config)), exclude_cwds=(str(config.run_dir),)
    )
    return [
        {"source": "sessions", "day": day, **row}
        for day in days
        for row in DIGEST.digest(config.transcripts, date.fromisoformat(day), None, opts)
    ]


def collect(config, source, days, until, gh=run_gh):
    if source == "sessions":
        return collect_sessions(config, days)
    if source == "git":
        return collect_git(config, days, until)
    if source == "github":
        return collect_github(days, until, gh)
    raise Refused(f"{source} is not a local source; the harvesting model reads it")


# CLI


def env_paths(name):
    return tuple(Path(p).expanduser() for p in os.environ.get(name, "").split(os.pathsep) if p)


def main(argv=None, now=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--vault", type=Path, default=Path(os.environ.get("BRAIN_DIR", "~/brain")))
    parser.add_argument("--state-dir", type=Path, default=Path(os.environ.get("BRAIN_STATE_DIR", "~/.local/state/brain")))
    parser.add_argument(
        "--repo-root", type=Path, action="append", help="dir to scan for git checkouts (default: $BRAIN_REPO_ROOTS)"
    )
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("begin", help="claim a run; prints its nonce, sources, and days")
    p_collect = sub.add_parser("collect", help="print a local source's rows as JSON lines")
    p_collect.add_argument("--source", required=True, choices=LOCAL_SOURCES)
    scope = p_collect.add_mutually_exclusive_group(required=True)
    scope.add_argument("--run", help="the active run's days")
    scope.add_argument("--day", type=date.fromisoformat, action="append", help="an explicit day, outside any run")
    p_finish = sub.add_parser("finish", help="release the run, advancing completed sources")
    p_finish.add_argument("--run", required=True)
    p_finish.add_argument("--complete", default="", help="comma-separated sources the run fully harvested")
    args = parser.parse_args(argv)

    now = now or datetime.now().astimezone()
    config = Config(
        vault=args.vault.expanduser(),
        state_dir=args.state_dir.expanduser(),
        repo_roots=tuple(p.expanduser() for p in args.repo_root) if args.repo_root else env_paths("BRAIN_REPO_ROOTS"),
    )
    try:
        if args.command == "begin":
            run = begin(config, now)
            print(json.dumps({"run": run.nonce, "sources": run.sources, "days": run.days, "truncated": run.truncated}))
        elif args.command == "collect":
            if args.run:
                with locked(config.state_dir):
                    run = active_run(config, args.run)
                days, until = run.days, run.started
            else:
                days, until = tuple(sorted(d.isoformat() for d in set(args.day))), now.isoformat()
            for row in collect(config, args.source, days, until):
                print(json.dumps(row, ensure_ascii=False))
        else:
            complete = [s for s in args.complete.split(",") if s]
            print(json.dumps(finish(config, args.run, complete, clock=lambda: now)))
    except (Refused, OSError, subprocess.CalledProcessError) as err:
        detail = err.stderr.strip() if isinstance(err, subprocess.CalledProcessError) and err.stderr else err
        print(f"brain-run: refused: {detail}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
