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

LOCAL_SOURCES = ("sessions", "git", "github")
CONNECTOR_SOURCES = ("chat", "mail", "calendar", "tracker")
SOURCES = LOCAL_SOURCES + CONNECTOR_SOURCES
# A long backlog in one run would blow the turn budget and never advance anything.
DAY_CAP = 5
# Late-night work belongs to the day it started; matches the skill's "before 04:00" rule.
ROLLOVER = time(4)
# Longer than any run can take, so an abandoned claim can't block harvests forever.
STALE_AFTER = timedelta(hours=3)
REPO_DEPTH = 3
# Reflog actions that are work; checkouts and resets are navigation.
GIT_ACTIONS = ("commit", "merge", "pull", "rebase (finish)", "cherry-pick", "revert")
SUBJECT_CHARS = 200
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
    exclude_cwds: tuple[str, ...] = ()
    transcripts: Path = field(default_factory=DIGEST.default_root)


@dataclass(frozen=True)
class Run:
    nonce: str
    started: str  # aware ISO
    head0: str
    cursors_read: dict
    days: tuple[str, ...]
    advance_to: str  # aware ISO: `started`, or the end of the last day when the backlog was capped
    truncated: bool


# Pure core


def work_day(moment):
    return (moment - timedelta(hours=ROLLOVER.hour, minutes=ROLLOVER.minute)).date()


def day_end(day, tz):
    return datetime.combine(day + timedelta(days=1), ROLLOVER, tzinfo=tz)


def plan_days(cursors, default_day, today, tz, cap=DAY_CAP):
    """Days to rebuild and whether the backlog was cut short."""
    starts = [work_day(parse_time(cursors[s], tz)) if s in cursors else default_day for s in SOURCES]
    start = min(min(starts), today)
    days = [start + timedelta(days=i) for i in range((today - start).days + 1)]
    return days[:cap], len(days) > cap


def advance(cursors_now, cursors_read, complete, target):
    """Move each completed source to target, unless another run moved it since this one read it."""
    return {
        **cursors_now,
        **{s: target for s in complete if cursors_now.get(s) == cursors_read.get(s)},
    }


def parse_time(value, tz):
    moment = datetime.fromisoformat(value)
    return moment.astimezone(tz) if tz else moment.astimezone()


def window(run, tz):
    days = [date.fromisoformat(d) for d in run.days]
    start = datetime.combine(days[0], time.min, tzinfo=tz) if tz else datetime.combine(days[0], time.min).astimezone()
    return start, min(parse_time(run.started, tz), day_end(days[-1], tz))


def ticket_prefixes(vault_config):
    """Keys listed one per line under the vault CLAUDE.md's `## Ticket prefixes`."""
    section = re.search(r"^## Ticket prefixes\n(.*?)(?=^## |\Z)", vault_config, re.MULTILINE | re.DOTALL)
    lines = section.group(1).splitlines() if section else []
    return tuple(line.strip() for line in lines if TICKET_KEY_RE.match(line.strip()))


def reflog_rows(repo, lines, start, end, tz):
    rows = []
    for line in lines:
        sha, selector, subject = (line.split("\0") + ["", ""])[:3]
        stamp = re.search(r"@\{(.+)\}", selector)
        if not stamp:
            continue
        moment = parse_time(stamp.group(1), tz)
        action, _, rest = subject.partition(": ")
        if not (start <= moment < end) or not action.startswith(GIT_ACTIONS):
            continue
        rows.append(
            {
                "source": "git",
                "repo": str(repo),
                "time": moment.isoformat(),
                "action": action,
                "subject": DIGEST.truncate(DIGEST.clean(rest), SUBJECT_CHARS),
                "sha": sha[:12],
            }
        )
    return rows


def pr_rows(results_by_role):
    """Merge `gh search prs` results by URL, keeping every role Sam had on the PR."""
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


def git(repo, *args, check=True):
    config = [arg for kv in COMMIT.SAFE_CONFIG for arg in ("-c", kv)]
    env = {k: v for k, v in os.environ.items() if k not in COMMIT.REPO_ENV}
    return subprocess.run(["git", "-C", str(repo), *config, *args], env=env, check=check, capture_output=True, text=True)


def read_json(path, default):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return default


def write_json(path, value):
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    tmp.replace(path)


@contextlib.contextmanager
def locked(state_dir):
    state_dir.mkdir(parents=True, exist_ok=True)
    with open(state_dir / "lock", "w") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        yield


def vault_dirty(vault):
    return COMMIT.changed_paths(git(vault, "status", "--porcelain=v1", "-z", "--untracked-files=all").stdout)


def newest_daily(vault):
    days = sorted(p.stem for p in (vault / "daily").glob("*.md") if re.fullmatch(r"\d{4}-\d{2}-\d{2}", p.stem))
    return date.fromisoformat(days[-1]) if days else None


def load_run(record):
    return Run(**{**record, "days": tuple(record["days"])})


def begin(config, now, tz=None):
    with locked(config.state_dir):
        active = read_json(config.state_dir / "active.json", None)
        if active and now - parse_time(active["started"], tz) < STALE_AFTER:
            raise Refused(f"run {active['nonce']} started {active['started']} is still in progress")
        if dirty := vault_dirty(config.vault):
            raise Refused("vault has uncommitted changes: " + ", ".join(sorted(set(dirty))))
        cursors = read_json(config.state_dir / "cursors.json", {})
        today = work_day(now)
        days, truncated = plan_days(cursors, newest_daily(config.vault) or today, today, tz)
        run = Run(
            nonce=secrets.token_hex(8),
            started=now.isoformat(),
            head0=git(config.vault, "rev-parse", "HEAD").stdout.strip(),
            cursors_read=cursors,
            days=tuple(d.isoformat() for d in days),
            advance_to=(day_end(days[-1], tz) if truncated else now).isoformat(),
            truncated=truncated,
        )
        write_json(config.state_dir / "active.json", asdict(run))
        return run


def active_run(config, nonce):
    active = read_json(config.state_dir / "active.json", None)
    if not active or active["nonce"] != nonce:
        raise Refused(f"run {nonce} is not the active run")
    return load_run(active)


def finish(config, nonce, complete):
    """Release the run; advance `complete` sources only if the vault holds this run's work committed."""
    if unknown := sorted(set(complete) - set(SOURCES)):
        raise Refused("unknown sources: " + ", ".join(unknown))
    with locked(config.state_dir):
        run = active_run(config, nonce)
        (config.state_dir / "active.json").unlink()
        if dirty := vault_dirty(config.vault):
            raise Refused("vault has uncommitted changes, nothing advanced: " + ", ".join(sorted(set(dirty))))
        if git(config.vault, "merge-base", "--is-ancestor", run.head0, "HEAD", check=False).returncode != 0:
            raise Refused("vault history no longer contains the run's starting commit, nothing advanced")
        now = read_json(config.state_dir / "cursors.json", {})
        updated = advance(now, run.cursors_read, complete, run.advance_to)
        write_json(config.state_dir / "cursors.json", updated)
        moved = [s for s in SOURCES if updated.get(s) != now.get(s)]
        return {"advanced": moved, "held": [s for s in SOURCES if s not in moved]}


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


def worktrees(repo):
    out = git(repo, "worktree", "list", "--porcelain", check=False).stdout
    return [Path(line[len("worktree ") :]) for line in out.splitlines() if line.startswith("worktree ")] or [repo]


def collect_git(config, run, tz):
    start, end = window(run, tz)
    rows = []
    for repo in find_repos(config.repo_roots):
        for tree in worktrees(repo):
            out = git(tree, "log", "-g", "--date=iso-strict", "--format=%H%x00%gd%x00%gs", "HEAD", check=False).stdout
            rows += reflog_rows(tree, out.splitlines(), start, end, tz)
    return sorted(rows, key=lambda r: r["time"])


GH_FIELDS = "url,title,state,isDraft,updatedAt,closedAt"
GH_ROLES = {"author": "--author=@me", "reviewer": "--reviewed-by=@me", "commenter": "--commenter=@me"}


def collect_github(run, gh):
    since = run.days[0]
    results = {
        role: json.loads(gh(["search", "prs", flag, f"--updated=>={since}", "--limit", "100", "--json", GH_FIELDS]))
        for role, flag in GH_ROLES.items()
    }
    return pr_rows(results)


def run_gh(args):
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout


def collect_sessions(config, run):
    vault_config = (config.vault / "CLAUDE.md").read_text(encoding="utf-8") if (config.vault / "CLAUDE.md").exists() else ""
    opts = DIGEST.Options(ticket_prefixes=ticket_prefixes(vault_config), exclude_cwds=config.exclude_cwds)
    return [
        {"source": "sessions", "day": day, **row}
        for day in run.days
        for row in DIGEST.digest(config.transcripts, date.fromisoformat(day), None, opts)
    ]


def collect(config, run, source, tz=None, gh=run_gh):
    if source == "sessions":
        return collect_sessions(config, run)
    if source == "git":
        return collect_git(config, run, tz)
    if source == "github":
        return collect_github(run, gh)
    raise Refused(f"{source} is not a local source; the harvesting model reads it")


# CLI


def load_config(path):
    raw = read_json(Path(path).expanduser(), None)
    if raw is None:
        raise Refused(f"no config at {path}")
    return Config(
        vault=Path(raw["vault"]).expanduser(),
        state_dir=Path(raw["state_dir"]).expanduser(),
        repo_roots=tuple(Path(p).expanduser() for p in raw.get("repo_roots", [])),
        exclude_cwds=tuple(str(Path(p).expanduser()) for p in raw.get("exclude_cwds", [])),
    )


def main(argv=None, now=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--config", default="~/.config/brain/autopilot.json")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("begin", help="claim a run; prints its days and nonce")
    p_collect = sub.add_parser("collect", help="print a local source's rows for the run as JSON lines")
    p_collect.add_argument("--run", required=True)
    p_collect.add_argument("--source", required=True, choices=LOCAL_SOURCES)
    p_finish = sub.add_parser("finish", help="release the run, advancing completed sources")
    p_finish.add_argument("--run", required=True)
    p_finish.add_argument("--complete", default="", help="comma-separated sources the run fully harvested")
    args = parser.parse_args(argv)

    try:
        config = load_config(args.config)
        if args.command == "begin":
            run = begin(config, now or datetime.now().astimezone())
            print(json.dumps({"run": run.nonce, "days": run.days, "truncated": run.truncated, "sources": SOURCES}))
        elif args.command == "collect":
            with locked(config.state_dir):
                run = active_run(config, args.run)
            for row in collect(config, run, args.source):
                print(json.dumps(row, ensure_ascii=False))
        else:
            complete = [s for s in args.complete.split(",") if s]
            print(json.dumps(finish(config, args.run, complete)))
    except (Refused, subprocess.CalledProcessError) as err:
        detail = err.stderr.strip() if isinstance(err, subprocess.CalledProcessError) and err.stderr else err
        print(f"brain-run: refused: {detail}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
