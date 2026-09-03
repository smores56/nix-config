"""sdlc state store: markdown design docs + machine state over a git repo.

Layout under the state root (default ~/code/github.com/smores56/sdlc-state):

    features/<owner>--<repo>--<slug>/
        design.md   — design doc, reviewed by the human
        state.json  — machine state: title, repo, status, approval, claim, tasks

Every mutation commits to the state repo and pushes to origin. Set
SDLC_STATE_DIR to override the root; SDLC_NO_PUSH=1 disables pushes.
"""

import getpass
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

DEFAULT_ROOT = "~/code/github.com/smores56/sdlc-state"
EXPECTED_ORIGIN = "smores56/sdlc-state"
KEY_RE = re.compile(r"^[A-Za-z0-9_.-]+--[A-Za-z0-9_.-]+--[A-Za-z0-9_-]+$")


def state_root():
    root = os.environ.get("SDLC_STATE_DIR") or os.path.expanduser(DEFAULT_ROOT)
    return os.path.abspath(root)


def _fail(message):
    print(f"sdlc: {message}", file=sys.stderr)
    raise SystemExit(1)


def require_root():
    root = state_root()
    if not os.path.isdir(root):
        _fail(
            f"state repo missing at {root}\n"
            f"  clone it: git clone git@github.com:smores56/sdlc-state.git {root}\n"
            "  or set SDLC_STATE_DIR to an existing sdlc-state checkout"
        )
    if not os.path.isdir(os.path.join(root, ".git")):
        _fail(f"{root} is not a git checkout of the sdlc-state repo")
    origin = _origin_url(root)
    if origin and EXPECTED_ORIGIN not in origin:
        _fail(
            f"{root} origin is {origin}, expected a smores56/sdlc-state remote — "
            "refusing to operate on the wrong repo"
        )
    return root


def _origin_url(root):
    proc = subprocess.run(
        ["git", "-C", root, "remote", "get-url", "origin"],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        return None
    return proc.stdout.strip()


def now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def who():
    return f"{getpass.getuser()}@{socket.gethostname()}"


def feature_dir(root, key):
    return os.path.join(root, "features", key)


def list_keys(root):
    base = os.path.join(root, "features")
    if not os.path.isdir(base):
        return []
    keys = []
    for d in sorted(os.listdir(base)):
        path = os.path.join(base, d)
        if os.path.islink(path) or not os.path.isdir(path):
            continue
        if KEY_RE.match(d):
            keys.append(d)
    return keys


def _slug(key):
    return key.rsplit("--", 1)[-1]


def resolve(root, query):
    """Resolve a feature key or an unambiguous slug to a key."""
    keys = list_keys(root)
    direct = [k for k in keys if k == query]
    if direct:
        return direct[0]
    if not re.match(r"^[A-Za-z0-9_-]+$", query):
        _fail(f"no feature {query!r}")
    matches = [k for k in keys if _slug(k) == query]
    if len(matches) == 1:
        return matches[0]
    if len(matches) > 1:
        _fail(f"slug {query!r} is ambiguous: {', '.join(matches)}")
    _fail(f"no feature {query!r} (expected <owner>--<repo>--<slug> or slug)")


def _read_regular(path, what):
    """Read a file, refusing symlinks (feature dirs arrive from other machines)."""
    if os.path.islink(path):
        _fail(f"{what} is a symlink at {path} — refusing")
    try:
        with open(path) as f:
            return f.read()
    except FileNotFoundError:
        _fail(f"{what} missing at {path}")


def load(root, key):
    path = feature_dir(root, key)
    state_path = os.path.join(path, "state.json")
    if not os.path.isfile(state_path):
        _fail(f"{key}: state.json missing at {path}")
    if os.path.islink(state_path):
        _fail(f"{key}: state.json is a symlink — refusing")
    try:
        with open(state_path) as f:
            state = json.load(f)
    except json.JSONDecodeError as error:
        _fail(f"{key}: state.json is corrupt: {error}")
    state["key"] = key
    design_path_ = os.path.join(path, "design.md")
    state["design"] = _read_regular(design_path_, f"{key}: design.md") if os.path.exists(design_path_) else ""
    return state


def design_path(root, key):
    return os.path.join(feature_dir(root, key), "design.md")


def _write_new(path, content):
    """Write via an exclusive temp file + atomic rename (symlink-safe)."""
    directory = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".tmp-", suffix=os.path.basename(path))
    try:
        with os.fdopen(fd, "w") as f:
            f.write(content)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def save(root, key, state):
    state_path = os.path.join(feature_dir(root, key), "state.json")
    payload = {k: v for k, v in state.items() if k not in ("key", "design")}
    _write_new(state_path, json.dumps(payload, indent=2, sort_keys=True) + "\n")
    commit(root, f"{key}: update state")


def create(root, key, repo, title):
    path = feature_dir(root, key)
    if os.path.isdir(path):
        _fail(f"feature already exists: {key}")
    os.makedirs(path)
    state = {
        "title": title,
        "repo": repo,
        "created": now(),
        "status": "active",
        "approval": None,
        "claim": None,
        "tasks": [],
    }
    _write_new(os.path.join(path, "design.md"), f"# {title}\n\n")
    _write_new(os.path.join(path, "state.json"), json.dumps(state, indent=2, sort_keys=True) + "\n")
    commit(root, f"{key}: create feature")
    return state


def write_design(root, key, content):
    _write_new(design_path(root, key), content)
    commit(root, f"{key}: edit design")


def is_git_repo(root):
    proc = subprocess.run(
        ["git", "-C", root, "rev-parse", "--git-dir"],
        capture_output=True,
        text=True,
    )
    return proc.returncode == 0


def _git(root, *args, check=True):
    proc = subprocess.run(["git", "-C", root, *args], capture_output=True, text=True)
    if check and proc.returncode != 0:
        _fail(f"git {args[0]} failed: {proc.stderr.strip()}")
    return proc


def _sanitize_url(text):
    # Strip userinfo from URLs in git error output (token-in-URL leakage).
    return re.sub(r"(https?://)[^/@\s]+@", r"\1***@", text)


def commit(root, message):
    if not is_git_repo(root):
        return
    # Scope to features/ — the state repo root may hold unrelated files.
    _git(root, "add", "--", "features")
    proc = _git(root, "diff", "--cached", "--quiet", check=False)
    if proc.returncode != 0:
        _git(root, "commit", "-q", "-m", message)
        if os.environ.get("SDLC_NO_PUSH"):
            return
        if _origin_url(root) is None:
            return
        push = _git(root, "push", "-q", check=False)
        if push.returncode != 0:
            _fail(
                f"state committed locally but push failed: {_sanitize_url(push.stderr.strip())}\n"
                f"  fix and re-run: git -C {root} push"
            )


def claim(root, key, release=False):
    state = load(root, key)
    if release:
        current = state.get("claim")
        if current and current.get("by") != who():
            _fail(f"{key} claimed by {current['by']} — only the claimer may release")
        state["claim"] = None
        save(root, key, state)
        print(f"sdlc: released claim on {key}")
        return 0
    if state.get("claim"):
        _fail(f"{key} already claimed by {state['claim']['by']}")
    state["claim"] = {"by": who(), "at": now()}
    save(root, key, state)
    print(f"sdlc: claimed {key} as {who()}")
    return 0


def task_ids(state):
    used = {t["id"] for t in state["tasks"]}
    n = 1
    while f"T{n}" in used:
        n += 1
    return f"T{n}"


def which_editor():
    return os.environ.get("EDITOR") or os.environ.get("VISUAL") or "hx"


def run_editor(path):
    try:
        return subprocess.call([which_editor(), path])
    except FileNotFoundError:
        _fail(f"editor {which_editor()!r} not found (set $EDITOR)")


def repo_from_cwd():
    proc = subprocess.run(
        ["git", "remote", "get-url", "origin"],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        return None
    url = proc.stdout.strip()
    match = re.match(r"(?:git@|ssh://git@[^/]+/|https?://[^/]+/)([^/:]+)/([^/.]+)(?:\.git)?$", url)
    if not match:
        return None
    return f"{match.group(1)}/{match.group(2)}"
