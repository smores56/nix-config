#!/usr/bin/env python3
"""Stateless sdlc CLI: GitHub Issues are the system of record.

Global and self-contained: it needs `gh` and nothing from this repo's justfile
or local state. Feature = issue labeled type:feature; tasks = sub-issues with
blocked-by links; approval = the status:approved label plus a comment holding
the canonical design hash. `ui` uses `tv` when present; `review` launches
`revdiff`.
"""

import argparse
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from collections import namedtuple

DEFAULT_REPO = "smores56/sdlc"
HASH_RE = re.compile(r"(?m)^[ \t]*Approved design sha256:([0-9a-f]{64})[ \t]*$")
TERMINAL = ("done", "canceled")

FEATURE_FIELDS = "number,title,body,state,labels,comments,subIssues,url"
TASK_FIELDS = "number,title,state,labels,blockedBy"
NODE_FIELDS = "number,title,state,labels"

FEATURE_GRAPH_QUERY = """
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    issue(number: $number) {
      number title body state url
      labels(first: 50) { nodes { name } }
      comments(last: 100) { nodes { author { login } body createdAt } }
      subIssues(first: 100) {
        nodes {
          number title state
          labels(first: 50) { nodes { name } }
          blockedBy(first: 50) { nodes { number state title } }
        }
      }
    }
  }
}
"""

ACTIONS = ("show", "status", "review", "comment", "next", "approve", "complete", "cancel")
ACTION_HELP = {
    "show": "print the body and comments",
    "status": "show approval and task state",
    "review": "open revdiff and post the notes",
    "comment": "open $EDITOR and post a comment",
    "next": "print the next ready task",
    "approve": "record design approval (TTY only)",
    "complete": "close as done (terminal)",
    "cancel": "close as canceled (terminal)",
}
REVDIFF_NOTE_RE = re.compile(
    r"^## (?P<file>.+?):(?P<start>\d+)(?:-(?P<end>\d+))? \((?P<type>\+|-| )\)$"
)
REVDIFF_FILE_RE = re.compile(r"^## (?P<file>.+) \(file-level\)$")
REVIEW_MARKER_RE = re.compile(r"<!-- sdlc-review:n\d+:[0-9a-f]{12} -->")

Approval = namedtuple("Approval", "state design approved comment reason")
ReviewNote = namedtuple("ReviewNote", "file start end text")


class CliError(Exception):
    """A user-facing failure; main() prints it and exits nonzero."""


_CONTROL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]")


def clean(value):
    """Strip control characters from untrusted issue text before rendering."""
    return _CONTROL.sub("", value) if isinstance(value, str) else value


def one_line(value):
    """Clean text and collapse tabs/newlines so it fits one row or prompt."""
    return clean(value).replace("\t", " ").replace("\r", " ").replace("\n", " ")


# --- gh plumbing ------------------------------------------------------------


def gh(*args, input=None):
    try:
        proc = subprocess.run(["gh", *args], capture_output=True, text=True, input=input)
    except FileNotFoundError:
        raise CliError("gh not found on PATH")
    if proc.returncode != 0:
        detail = proc.stderr.strip() or proc.stdout.strip() or "exit %d" % proc.returncode
        raise CliError("gh %s failed: %s" % (" ".join(args[:2]), detail))
    return proc.stdout


def gh_json(*args):
    out = gh(*args)
    try:
        return json.loads(out)
    except ValueError:
        raise CliError("gh %s returned invalid JSON" % " ".join(args[:2]))


def fetch_issue(repo, number, fields=FEATURE_FIELDS):
    return gh_json("issue", "view", str(number), "--repo", repo, "--json", fields)


def split_repo(repo, what="registry repo"):
    if "/" not in repo:
        raise CliError("%s must be owner/name, got %r" % (what, repo))
    return repo.split("/", 1)


def fetch_feature_graph(repo, number):
    """One GraphQL round trip: the feature, its comments, and its task graph."""
    owner, name = split_repo(repo)
    out = gh(
        "api",
        "graphql",
        "-F",
        "owner=%s" % owner,
        "-F",
        "name=%s" % name,
        "-F",
        "number=%d" % int(number),
        "-f",
        "query=%s" % FEATURE_GRAPH_QUERY,
    )
    try:
        issue = json.loads(out)["data"]["repository"]["issue"]
    except (ValueError, KeyError, TypeError):
        raise CliError("gh api graphql returned an unexpected payload")
    if not issue:
        raise CliError("issue #%s not found in %s" % (number, repo))
    issue["body"] = issue.get("body") or ""
    issue["labels"] = node_list(issue.get("labels"))
    issue["comments"] = node_list(issue.get("comments"))
    tasks = node_list(issue.get("subIssues"))
    for task in tasks:
        task["labels"] = node_list(task.get("labels"))
    issue["subIssues"] = {"nodes": tasks, "totalCount": len(tasks)}
    return issue


def registry_repo():
    return os.environ.get("SDLC_REPO") or DEFAULT_REPO


def node_list(value):
    """GitHub returns {nodes,totalCount}; tolerate plain arrays too."""
    if isinstance(value, dict):
        return value.get("nodes") or []
    return value or []


def labels_of(issue):
    return {entry.get("name") for entry in issue.get("labels") or [] if entry.get("name")}


def lifecycle_of(issue):
    labels = labels_of(issue)
    for status in ("done", "canceled", "in-progress", "todo"):
        if "status:%s" % status in labels:
            return status
    return None


def display_status(issue):
    status = lifecycle_of(issue)
    if status is None:
        status = "closed" if issue.get("state") == "CLOSED" else "open"
    return status


def repo_names(issue):
    names = sorted(name[len("repo:") :] for name in labels_of(issue) if name.startswith("repo:"))
    return ",".join(names)


# --- design hash ------------------------------------------------------------

DESIGN_HEADER_RE = re.compile(r"(?ms)^## Design[ \t]*\n(.*?)(?=^## |\Z)")
ANNOTATION_PREFIX = "> Sam:"


def design_section(body):
    """Canonical `## Design` content, or None.

    Rules (T1): LF line endings, trailing whitespace stripped, annotation lines
    dropped, leading/trailing blank lines removed, joined with LF, no final
    newline.
    """
    if not body:
        return None
    text = body.replace("\r\n", "\n").replace("\r", "\n")
    match = DESIGN_HEADER_RE.search(text)
    if not match:
        return None
    lines = [line.rstrip() for line in match.group(1).split("\n")]
    lines = [line for line in lines if not line.lstrip().startswith(ANNOTATION_PREFIX)]
    while lines and not lines[0]:
        lines.pop(0)
    while lines and not lines[-1]:
        lines.pop()
    return "\n".join(lines)


def design_hash(body):
    section = design_section(body)
    if section is None:
        return None
    return hashlib.sha256(section.encode("utf-8")).hexdigest()


def approval_comment(issue):
    # Only a comment that is exactly the approval line counts. Review text can
    # quote an approval (or an agent can paste one), so a substring match would
    # let an unrelated comment re-point the approved hash.
    for comment in reversed(issue.get("comments") or []):
        body = (comment.get("body") or "").strip()
        match = HASH_RE.fullmatch(body)
        if match:
            return match.group(1), comment
    return None, None


def approval_state(issue):
    """needs-reapproval beats approved; a missing hash is not approval."""
    current = design_hash(issue.get("body"))
    approved, comment = approval_comment(issue)
    labels = labels_of(issue)
    if current is None:
        return Approval("missing", current, approved, comment, "no '## Design' section")
    if "status:needs-reapproval" in labels:
        return Approval("stale", current, approved, comment, "status:needs-reapproval")
    if "status:approved" not in labels:
        return Approval("missing", current, approved, comment, "no status:approved label")
    if approved is None:
        return Approval("missing", current, approved, comment, "approved without a sha256 comment")
    if approved != current:
        return Approval("stale", current, approved, comment, "design changed since approval")
    return Approval("approved", current, approved, comment, "")


def comment_author(comment):
    if not comment:
        return "-"
    return (comment.get("author") or {}).get("login") or "-"


def comment_date(comment):
    if not comment:
        return "-"
    return comment.get("createdAt") or "-"


# --- features and tasks -----------------------------------------------------


def feature_issues(repo, all_states=False):
    issues = gh_json(
        "issue", "list", "--repo", repo,
        "--state", "all" if all_states else "open",
        "--json", FEATURE_FIELDS, "--limit", "500",
    )
    features = []
    for issue in issues:
        if "type:feature" not in labels_of(issue):
            continue
        # Label writes can lag the index ~15s; decide client-side instead of
        # trusting a server-side --label filter.
        if not all_states and (
            issue.get("state") == "CLOSED" or lifecycle_of(issue) in TERMINAL
        ):
            continue
        features.append(issue)
    return features


def resolve_number(repo, ref):
    if ref is None:
        raise CliError("a feature number or title is required")
    if str(ref).isdigit():
        return int(ref)
    needle = str(ref).lower()
    matches = [
        feature
        for feature in feature_issues(repo, all_states=True)
        if needle in (feature.get("title") or "").lower()
    ]
    if not matches:
        raise CliError("no feature matches %r" % ref)
    if len(matches) > 1:
        listing = ", ".join("#%d %s" % (feature["number"], feature["title"]) for feature in matches)
        raise CliError("%r is ambiguous: %s" % (ref, listing))
    return matches[0]["number"]


def resolve_feature(repo, ref):
    if str(ref).isdigit():
        return fetch_issue(repo, int(ref))
    return fetch_issue(repo, resolve_number(repo, ref))


def open_blockers(task):
    return [node for node in node_list(task.get("blockedBy")) if node.get("state") == "OPEN"]


def task_state(task):
    if task.get("state") == "CLOSED":
        return "closed"
    if open_blockers(task):
        return "blocked"
    status = lifecycle_of(task)
    return "ready" if status == "todo" else status or "open"


def sub_tasks(repo, feature):
    nodes = node_list(feature.get("subIssues"))
    if all("blockedBy" in node for node in nodes):
        return nodes
    return [fetch_issue(repo, node["number"], TASK_FIELDS) for node in nodes]


def task_counts(tasks):
    open_count = ready = blocked = 0
    for task in tasks:
        state = task_state(task)
        open_count += task.get("state") != "CLOSED"
        ready += state == "ready"
        blocked += state == "blocked"
    return open_count, ready, blocked


# --- picker -----------------------------------------------------------------


def pick(candidates, header="sdlc features"):
    """tv, then fzf, then a numbered prompt. Returns one candidate line.

    Only stdout is captured: both TUIs paint on stderr, so capturing that
    hides the interface while they wait for keys.
    """
    if not candidates:
        raise CliError("nothing to pick")
    if shutil.which("tv"):
        handle, path = tempfile.mkstemp(prefix="sdlc-", suffix=".txt")
        try:
            with os.fdopen(handle, "w") as fh:
                fh.write("\n".join(candidates) + "\n")
            proc = subprocess.run(
                [
                    "tv",
                    "--source-command",
                    "cat %s" % shlex.quote(path),
                    "--no-preview",
                    "--input-header",
                    header,
                ],
                stdout=subprocess.PIPE,
                text=True,
            )
        finally:
            os.unlink(path)
    elif shutil.which("fzf"):
        proc = subprocess.run(
            ["fzf", "--delimiter", "\t", "--with-nth", "1,2,3,4"],
            input="\n".join(candidates) + "\n",
            stdout=subprocess.PIPE,
            text=True,
        )
    else:
        for index, candidate in enumerate(candidates, 1):
            sys.stderr.write("  %d) %s\n" % (index, candidate))
        sys.stderr.write("pick: ")
        sys.stderr.flush()
        answer = sys.stdin.readline().strip()
        if not answer:
            raise CliError("no selection")
        if answer.isdigit() and 1 <= int(answer) <= len(candidates):
            return candidates[int(answer) - 1]
        for candidate in candidates:
            if answer in candidate:
                return candidate
        raise CliError("no matching selection: %s" % answer)
    if proc.returncode != 0 or not proc.stdout.strip():
        raise CliError("selection canceled")
    return proc.stdout.splitlines()[0]


def summary(feature):
    """The number/title/status/repo projection every list format shares."""
    return (
        feature["number"],
        one_line(feature.get("title") or ""),
        display_status(feature),
        repo_names(feature),
    )


def path_row(issue):
    number, title, status, repo = summary(issue)
    return "\t".join([str(number), title, status, clean(repo or "-")])


def preview_text(feature):
    number, title, status, repo = summary(feature)
    return "#%d %s\n[%s] %s\n\n%s\n" % (
        number,
        title,
        status,
        repo or "-",
        clean(feature.get("body") or ""),
    )


def excerpt(value, lines=20, chars=1600):
    """Truncate untrusted body text to a preview-sized excerpt."""
    text = clean(value or "").strip("\n")
    if not text.strip():
        return "(none)"
    rows = text.split("\n")
    kept = rows[:lines]
    clipped = len(rows) > lines
    out = "\n".join(kept)
    if len(out) > chars:
        out = out[:chars].rstrip()
        clipped = True
    return out + "\n…" if clipped else out


def feature_facts(feature):
    approval = approval_state(feature)
    return [
        "labels: %s" % (", ".join(sorted(labels_of(feature))) or "(none)"),
        "approval: %s (%s)"
        % (approval.state, clean(approval.reason) or "design matches"),
        "design sha256: %s" % ((approval.design or "-")[:12]),
    ]


def task_lines(feature):
    tasks = node_list(feature.get("subIssues"))
    open_tasks = [task for task in tasks if task.get("state") != "CLOSED"]
    return [
        "sub-issues: %d open of %d" % (len(open_tasks), len(tasks)),
    ] + [
        "  #%d [%s] %s"
        % (
            task["number"],
            "open" if task.get("state") != "CLOSED" else "closed",
            one_line(task.get("title") or ""),
        )
        for task in tasks[:8]
    ]


def action_preview(feature, action):
    """Describe one action against a feature, from local payload data only."""
    lines = [
        "#%d %s" % (feature["number"], one_line(feature.get("title") or "")),
        "[%s] %s" % (display_status(feature), repo_names(feature) or "-"),
        "",
        "## %s" % action,
        "%s: %s." % (action.capitalize(), ACTION_HELP[action]),
    ]
    if action in ("complete", "cancel"):
        lines += [
            "",
            "WARNING: this is terminal — #%d becomes %s and there is no reopen "
            "flow. Confirms with y/N before writing."
            % (feature["number"], "done" if action == "complete" else "canceled"),
        ]
    if action in ("show", "review"):
        lines += ["", "### body", excerpt(feature.get("body"))]
        comments = feature.get("comments") or []
        if action == "show" and comments:
            lines += [
                "",
                "### latest comment (%s)" % clean(comment_author(comments[-1])),
                excerpt((comments[-1].get("body") or ""), lines=6, chars=400),
            ]
    elif action == "status":
        lines += ["", "### state"] + feature_facts(feature) + task_lines(feature)
    elif action == "next":
        lines += ["", "### tasks"] + task_lines(feature)
    elif action == "approve":
        approval = approval_state(feature)
        lines += ["", "### approval"] + feature_facts(feature) + [
            "approved sha256: %s" % (approval.approved or "-"),
        ]
    return "\n".join(lines) + "\n"


def write_picker_channel(tmp, name, rows, previews, display, output="{split:\\t:0}"):
    """Write a tv channel whose previews are precomputed files, with no live gh calls.

    The preview command is a bare `cat` so it never blocks on the network; tv
    resolves {split:\t:0} from the row to choose the file.
    """
    cable = os.path.join(tmp, "cable")
    previews_dir = os.path.join(tmp, "previews")
    os.makedirs(cable)
    os.makedirs(previews_dir)
    source = os.path.join(tmp, "%s.tsv" % name)
    with open(source, "w") as fh:
        fh.write("\n".join(rows) + "\n")
    for key, text in previews.items():
        with open(os.path.join(previews_dir, "%s.md" % key), "w") as fh:
            fh.write(text)
    preview = "cat %s/{split:\\t:0}.md" % shlex.quote(previews_dir)
    channel = (
        '[metadata]\nname = "%s"\nrequirements = ["sdlc"]\n\n'
        '[source]\ncommand = "cat %s"\nentry_delimiter = "\\n"\n'
        'display = "%s"\n'
        'output = "%s"\n\n'
        '[preview]\ncommand = "%s"\n'
    ) % (name, shlex.quote(source), display, output, preview)
    with open(os.path.join(cable, "%s.toml" % name), "w") as fh:
        fh.write(channel)
    return cable


def write_picker_cable(tmp, features):
    """Write the feature list and its previews for tv, with no live gh calls."""
    return write_picker_channel(
        tmp,
        "sdlc-features",
        [path_row(feature) for feature in features],
        {str(feature["number"]): preview_text(feature) for feature in features},
        display="#{split:\\t:0} #{split:\\t:1} [#{split:\\t:2}] {split:\\t:3}",
    )


# --- review roundtrip -------------------------------------------------------


def parse_revdiff_annotations(text):
    """Parse revdiff's `## file:line (type)` records into anchored notes."""
    notes = []
    current = None
    for raw in (text or "").split("\n"):
        note_match = REVDIFF_NOTE_RE.match(raw)
        file_match = None if note_match else REVDIFF_FILE_RE.match(raw)
        if note_match or file_match:
            parsed = note_match or file_match
            current = {
                "file": parsed.group("file"),
                "start": int(note_match.group("start")) if note_match else None,
                "end": int(note_match.group("end")) if note_match and note_match.group("end") else None,
                "lines": [],
            }
            notes.append(current)
        elif current is not None:
            # revdiff prefixes body lines that would look like a record header.
            escaped = raw.startswith(" ") and raw[1:].lstrip(" ").startswith("## ")
            current["lines"].append(raw[1:] if escaped else raw)
    for note in notes:
        lines = note["lines"]
        while lines and not lines[-1].strip():
            lines.pop()
        note["text"] = "\n".join(line.rstrip() for line in lines).strip()
    return [
        ReviewNote(note["file"], note["start"], note["end"], note["text"])
        for note in notes
    ]


def review_quote(note, body_lines, limit=20):
    """Quote the reviewed body lines; anchors are advisory, the quote is exact."""
    if not note.start:
        return None
    start = max(note.start, 1)
    end = min(note.end or start, len(body_lines))
    if start > end:
        return None
    picked = body_lines[start - 1 : end][:limit]
    quoted = "\n".join("> " + clean(line) for line in picked)
    if end - start + 1 > limit:
        quoted += "\n> …"
    return quoted


def review_marker(feature_number, note, body_lines=None):
    # The temp body path changes every run. Hashing the quoted text keeps a
    # note stable across line shifts but re-posts it when the reviewed text
    # changes, which is exactly when the agent needs the new signal.
    quote = review_quote(note, body_lines) if body_lines is not None else None
    digest = hashlib.sha256(
        ("%s\n%s" % (note.text.strip(), quote or "")).encode("utf-8")
    ).hexdigest()[:12]
    return "<!-- sdlc-review:n%d:%s -->" % (feature_number, digest)


def render_review(feature_number, title, body, notes, markers=()):
    body_lines = body.split("\n")
    kept = []
    seen = set(markers)
    for note in notes:
        marker = review_marker(feature_number, note, body_lines)
        if marker in seen:
            continue
        seen.add(marker)
        kept.append((note, marker))
    if not kept:
        return ""
    digest = design_hash(body)
    header = "## Review — #%d %s (design sha256:%s)" % (
        feature_number,
        one_line(title),
        digest[:12] if digest else "none",
    )
    blocks = []
    for note, marker in kept:
        if note.start and note.end and note.end != note.start:
            location = "lines %d–%d" % (note.start, note.end)
        elif note.start:
            location = "line %d" % note.start
        else:
            location = "file"
        block = [marker, "### %s" % location]
        quote = review_quote(note, body_lines)
        if quote:
            block += ["", quote]
        block += ["", clean(note.text)]
        blocks.append("\n".join(block))
    return "\n\n".join([header] + blocks) + "\n"


# --- pickers ----------------------------------------------------------------


def cwd_repo_name(cwd=None):
    def run(*args):
        return subprocess.run(
            ["git", *args], cwd=cwd, capture_output=True, text=True
        )

    try:
        proc = run("remote", "get-url", "origin")
        if proc.returncode == 0 and proc.stdout.strip():
            name = re.sub(r"\.git$", "", proc.stdout.strip().rstrip("/"))
            name = re.split(r"[/:]", name)[-1]
            if name:
                return name
        proc = run("rev-parse", "--show-toplevel")
    except FileNotFoundError:
        return None
    if proc.returncode != 0:
        return None
    return os.path.basename(proc.stdout.strip()) or None


def pick_action(feature=None):
    """Pick an action. With a feature, each action previews what it will do.

    The feature payload is already in hand (or fetched once by cmd_ui), so the
    previews are precomputed files read by `cat`; the picker never runs gh.
    """
    if feature is None or not shutil.which("tv"):
        return pick(list(ACTIONS), header="sdlc actions").strip()
    rows = ["%s\t%s" % (action, ACTION_HELP[action]) for action in ACTIONS]
    with tempfile.TemporaryDirectory(prefix="sdlc-cable-") as tmp:
        cable = write_picker_channel(
            tmp,
            "sdlc-actions",
            rows,
            {action: action_preview(feature, action) for action in ACTIONS},
            display="#{split:\\t:0} {split:\\t:1}",
        )
        proc = subprocess.run(
            ["tv", "--cable-dir", cable, "sdlc-actions"],
            stdout=subprocess.PIPE,
            text=True,
        )
    if proc.returncode != 0 or not proc.stdout.strip():
        raise CliError("selection canceled")
    return proc.stdout.splitlines()[0].strip()


def pick_feature(repo, all_states=False, features=None):
    if features is None:
        features = feature_issues(repo, all_states=all_states)
    if not features:
        raise CliError("no active features in %s" % repo)
    cwd = cwd_repo_name()
    features.sort(key=lambda feature: 0 if cwd and cwd in repo_names(feature) else 1)
    rows = [path_row(feature) for feature in features]
    if not shutil.which("tv"):
        return int(pick(rows).split("\t")[0])

    with tempfile.TemporaryDirectory(prefix="sdlc-cable-") as tmp:
        cable = write_picker_cable(tmp, features)
        proc = subprocess.run(
            ["tv", "--cable-dir", cable, "sdlc-features"],
            stdout=subprocess.PIPE,
            text=True,
        )
    if proc.returncode != 0 or not proc.stdout.strip():
        raise CliError("selection canceled")
    selected = proc.stdout.splitlines()[0].strip()
    try:
        return int(selected)
    except ValueError:
        raise CliError("unexpected picker output: %r" % selected)


def confirm(prompt):
    sys.stderr.write("%s? [y/N] " % prompt)
    sys.stderr.flush()
    return sys.stdin.readline().strip().lower() in ("y", "yes")


# --- commands ---------------------------------------------------------------


def cmd_list(args):
    repo = args.repo or registry_repo()
    features = feature_issues(repo, all_states=args.all)
    if args.pick:
        print(pick([path_row(feature) for feature in features]).split("\t")[0])
        return
    if args.format == "path":
        for feature in features:
            print(path_row(feature))
        return
    if args.format == "json":
        rows = []
        for feature in features:
            number, title, status, repo = summary(feature)
            rows.append(
                {
                    "number": number,
                    "title": title,
                    "status": status,
                    "repo": repo,
                    "state": feature.get("state"),
                    "approval": approval_state(feature).state,
                    "url": feature.get("url"),
                }
            )
        print(json.dumps(rows, indent=2))
        return
    for feature in features:
        labels = labels_of(feature)
        status = display_status(feature)
        if "status:needs-reapproval" in labels:
            status += "+needs-reapproval"
        elif "status:approved" in labels:
            status += "+approved"
        print(
            "#%d [%s] %s %s"
            % (
                feature["number"],
                status,
                repo_names(feature) or "-",
                one_line(feature.get("title") or ""),
            )
        )


def cmd_show(args):
    repo = registry_repo()
    feature = resolve_feature(repo, args.feature)
    print(clean(feature.get("body") or ""))
    print("\n--- comments ---")
    comments = feature.get("comments") or []
    if not comments:
        print("(no comments)")
    for comment in comments:
        print(
            "\n[%s @ %s]\n%s"
            % (
                clean(comment_author(comment)),
                clean(comment_date(comment)),
                clean((comment.get("body") or "").strip()),
            )
        )


def cmd_status(args):
    repo = registry_repo()
    feature = fetch_feature_graph(repo, resolve_number(repo, args.feature))
    approval = approval_state(feature)
    tasks = sub_tasks(repo, feature)
    open_count, ready_count, blocked_count = task_counts(tasks)
    print("#%d %s" % (feature["number"], one_line(feature.get("title") or "")))
    print("state=%s labels=%s" % (feature.get("state"), one_line(",".join(sorted(labels_of(feature))))))
    print("design_sha256=%s" % (approval.design or "-"))
    print("approved_sha256=%s" % (approval.approved or "-"))
    print("approved_by=%s" % clean(comment_author(approval.comment)))
    print("approved_at=%s" % clean(comment_date(approval.comment)))
    print("approval=%s" % approval.state)
    if approval.state == "stale":
        print("WARN: design no longer matches the approval; re-approval required (%s)" % clean(approval.reason))
    elif approval.state == "missing":
        print("WARN: no recorded approval (%s)" % clean(approval.reason))
    print("tasks: open=%d ready=%d blocked=%d" % (open_count, ready_count, blocked_count))
    for task in tasks:
        state = task_state(task)
        blockers = open_blockers(task)
        suffix = " blocked_by=%s" % [node["number"] for node in blockers] if blockers else ""
        print("  #%d [%s] %s%s" % (task["number"], state, one_line(task.get("title") or ""), suffix))


def next_feature(repo, ref, do_pick):
    if ref is not None:
        return resolve_feature(repo, ref)
    features = feature_issues(repo, all_states=False)
    if not features:
        raise CliError("no active features in %s" % repo)
    if do_pick:
        chosen = pick([path_row(feature) for feature in features])
        return fetch_issue(repo, int(chosen.split("\t")[0]))
    return fetch_issue(repo, features[0]["number"])


def cmd_next(args):
    repo = registry_repo()
    if args.feature is not None:
        number = resolve_number(repo, args.feature)
    else:
        features = feature_issues(repo, all_states=False)
        if not features:
            raise CliError("no active features in %s" % repo)
        number = pick_feature(repo, features=features) if args.pick else features[0]["number"]
    feature = fetch_feature_graph(repo, number)
    approval = approval_state(feature)
    if approval.state == "stale":
        raise CliError(
            "#%d design changed since approval (now sha256:%s, approved %s); "
            "re-approval required: sdlc approve %d"
            % (
                feature["number"],
                (approval.design or "-")[:12],
                (approval.approved or "missing")[:12],
                feature["number"],
            )
        )
    if approval.state != "approved":
        raise CliError(
            "#%d is not approved (%s); ask the human, then run "
            "'sdlc approve %d'" % (feature["number"], approval.reason, feature["number"])
        )
    tasks = sub_tasks(repo, feature)
    ready = [task for task in tasks if task_state(task) == "ready"]
    if ready:
        task = ready[0]
        print("#%d %s  (feature #%d)" % (task["number"], one_line(task.get("title") or ""), feature["number"]))
        return
    open_tasks = [task for task in tasks if task.get("state") != "CLOSED"]
    blocked = [
        "  #%d is blocked by %s"
        % (task["number"], ", ".join("#%d" % node["number"] for node in open_blockers(task)))
        for task in open_tasks
        if open_blockers(task)
    ]
    if blocked:
        raise CliError("no ready tasks for #%d\n%s" % (feature["number"], "\n".join(blocked)))
    if not open_tasks:
        raise CliError("no ready tasks for #%d: no open tasks" % feature["number"])
    raise CliError("no ready tasks for #%d: no task is status:todo" % feature["number"])


def cmd_approve(args):
    if not args.yes and not sys.stdin.isatty():
        raise CliError("approve requires a TTY; pass --yes for a non-interactive approval")
    repo = registry_repo()
    feature = next_feature(repo, args.feature, args.pick)
    if "type:feature" not in labels_of(feature):
        raise CliError("#%d is not a feature (missing type:feature); refusing to approve" % feature["number"])
    digest = design_hash(feature.get("body"))
    if digest is None:
        raise CliError("#%d has no '## Design' section; refusing to approve" % feature["number"])
    prompts = (
        "approve #%d %r design sha256:%s? [y/N] "
        % (feature["number"], one_line(feature.get("title") or ""), digest)
    )
    if not args.yes:
        sys.stderr.write(prompts)
        sys.stderr.flush()
        answer = sys.stdin.readline().strip().lower()
        if answer not in ("y", "yes"):
            raise CliError("not approved")
    edit = ["issue", "edit", str(feature["number"]), "--repo", repo, "--add-label", "status:approved"]
    if "status:needs-reapproval" in labels_of(feature):
        edit += ["--remove-label", "status:needs-reapproval"]
    gh(*edit)
    gh(
        "issue", "comment", str(feature["number"]), "--repo", repo,
        "--body", "Approved design sha256:%s" % digest,
    )
    print("approved #%d sha256:%s" % (feature["number"], digest))


def parse_created_url(output):
    # `gh issue create` has no --json; the printed URL is the only handle.
    match = re.search(r"https?://\S+/issues/(\d+)", output)
    if match is None:
        raise CliError("could not parse the issue URL from gh output: %r" % output.strip())
    return int(match.group(1)), match.group(0)


def cmd_new(args):
    name = split_repo(args.repo, "--repo")[1]
    title = args.title or args.slug.replace("-", " ")
    body = "## Design\n\nPending.\n\n## Plan\n\n- [ ] T1: Scope the design\n"
    command = ["issue", "create", "--repo", registry_repo(), "--title", title, "--body", body]
    for label in ("type:feature", "repo:%s" % name, "status:todo"):
        command += ["--label", label]
    number, url = parse_created_url(gh(*command))
    print("#%d %s" % (number, url))


def task_number_map(repo, feature):
    """Map T-labels to issue numbers from the plan body and sub-issue titles."""
    mapping = {}
    for line in (feature.get("body") or "").splitlines():
        match = re.match(r"\s*-\s*\[[ xX]\]\s*(T\d+)\b.*?#(\d+)", line)
        if match:
            mapping[match.group(1).upper()] = int(match.group(2))
    for node in node_list(feature.get("subIssues")):
        title = node.get("title")
        if not title:
            title = fetch_issue(repo, node["number"], NODE_FIELDS).get("title") or ""
        match = re.match(r"\s*(T\d+)\b", title)
        label = match.group(1).upper() if match else None
        if label and label not in mapping:
            mapping[label] = node["number"]
    return mapping


def resolve_needs(repo, feature, needs):
    tokens = [token.strip() for token in (needs or "").split(",") if token.strip()]
    if not tokens:
        return []
    numbers = []
    mapping = None
    for token in tokens:
        direct = re.fullmatch(r"#?(\d+)", token)
        if direct:
            numbers.append(int(direct.group(1)))
            continue
        label = re.fullmatch(r"[Tt](\d+)", token)
        if label:
            if mapping is None:
                mapping = task_number_map(repo, feature)
            key = "T%s" % label.group(1)
            if key in mapping:
                numbers.append(mapping[key])
                continue
        raise CliError("cannot resolve --needs token %r for #%d" % (token, feature["number"]))
    return numbers


def cmd_task_add(args):
    repo = registry_repo()
    feature = resolve_feature(repo, args.feature)
    blocked = resolve_needs(repo, feature, args.needs)
    command = [
        "issue", "create", "--repo", repo, "--title", args.title,
        "--body", "Part of #%d." % feature["number"],
        "--parent", str(feature["number"]),
        "--label", "status:todo",
    ]
    if blocked:
        command += ["--blocked-by", ",".join(str(number) for number in blocked)]
    number, url = parse_created_url(gh(*command))
    print("#%d %s" % (number, url))


TASK_TRANSITIONS = {
    "start": ("status:in-progress", ("status:todo",)),
    "done": ("status:done", ("status:todo", "status:in-progress")),
    "cancel": ("status:canceled", ("status:done", "status:todo", "status:in-progress")),
}


def set_status(repo, number, add, remove, close):
    issue = fetch_issue(repo, number, NODE_FIELDS)
    labels = labels_of(issue)
    command = ["issue", "edit", str(number), "--repo", repo, "--add-label", add]
    for name in remove:
        if name in labels:
            command += ["--remove-label", name]
    gh(*command)
    if close:
        gh("issue", "close", str(number), "--repo", repo)


def cmd_task_transition(action):
    def run(args):
        repo = registry_repo()
        if not str(args.issue).isdigit():
            raise CliError("task %s takes an issue number, got %r" % (action, args.issue))
        add, remove = TASK_TRANSITIONS[action]
        set_status(repo, int(args.issue), add, remove, close=action in ("done", "cancel"))
        print("#%s %s" % (args.issue, add))

    return run


def cmd_feature_transition(terminal):
    def run(args):
        repo = registry_repo()
        if terminal == "done":
            feature = fetch_feature_graph(repo, resolve_number(repo, args.feature))
            open_tasks = [task for task in sub_tasks(repo, feature) if task.get("state") != "CLOSED"]
            if open_tasks:
                raise CliError(
                    "refusing to complete #%d: %d open task(s): %s"
                    % (
                        feature["number"],
                        len(open_tasks),
                        ", ".join("#%d" % task["number"] for task in open_tasks),
                    )
                )
        else:
            feature = resolve_feature(repo, args.feature)
        add = "status:%s" % terminal
        remove = tuple("status:%s" % name for name in ("todo", "in-progress", "done", "canceled") if name != terminal)
        set_status(repo, feature["number"], add, remove, close=True)
        print("#%d %s" % (feature["number"], add))

    return run


def cmd_review(args):
    repo = registry_repo()
    feature = resolve_feature(repo, args.feature)
    body = feature.get("body") or ""
    name = "issue-%d.md" % feature["number"]
    env = {key: value for key, value in os.environ.items() if key != "REVDIFF_OUTPUT"}
    try:
        proc = subprocess.run(
            ["revdiff", "--stdin", "--stdin-name", name],
            input=body,
            stdout=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            env=env,
        )
    except FileNotFoundError:
        raise CliError("revdiff not found on PATH")
    if proc.returncode not in (0, 10):
        raise CliError("revdiff exited %d" % proc.returncode)

    notes = parse_revdiff_annotations(proc.stdout)
    anchored = sorted({note.file for note in notes if note.file != name})
    if anchored:
        raise CliError(
            "revdiff anchored to %s, not %s: the body parsed as a diff"
            % (", ".join(anchored), name)
        )
    if not notes:
        print("no review notes (annotate in revdiff, then quit with q)")
        return
    existing = "\n".join(
        clean(comment.get("body") or "") for comment in feature.get("comments") or []
    )
    comment = render_review(
        feature["number"],
        feature.get("title") or "",
        body,
        notes,
        set(REVIEW_MARKER_RE.findall(existing)),
    )
    if not comment:
        print("no new review notes")
        return
    if args.dry_run:
        print(comment, end="")
        return
    url = gh(
        "issue", "comment", str(feature["number"]), "--repo", repo,
        "--body-file", "-", input=comment,
    )
    print(
        "posted review notes to #%d %s"
        % (feature["number"], url.strip() or "")
    )
    print('tell the agent: read #%d' % feature["number"])


def cmd_comment(args):
    repo = registry_repo()
    ref = args.feature if args.feature is not None else str(pick_feature(repo))
    feature = resolve_feature(repo, ref)
    try:
        proc = subprocess.run(
            ["gh", "issue", "comment", str(feature["number"]), "--repo", repo, "--editor"]
        )
    except FileNotFoundError:
        raise CliError("gh not found on PATH")
    if proc.returncode != 0:
        raise CliError("gh issue comment failed: exit %d" % proc.returncode)


def cmd_ui(args):
    if args.repo:
        os.environ["SDLC_REPO"] = args.repo
    repo = registry_repo()
    features = []
    actions = []
    for token in args.items:
        lowered = token.lower()
        if lowered in ACTIONS:
            actions.append(lowered)
        else:
            features.append(token)
    if len(features) > 1:
        raise CliError("expected at most one feature, got %s" % ", ".join(features))
    if len(actions) > 1:
        raise CliError("expected at most one action, got %s" % ", ".join(actions))

    if features:
        ref = features[0]
        # One fetch, only when the action picker will actually show previews.
        feature = None if actions else resolve_feature(repo, ref)
    else:
        pool = feature_issues(repo, all_states=args.all)
        number = pick_feature(repo, features=pool)
        ref = str(number)
        feature = next((item for item in pool if item["number"] == number), None)
    action = actions[0] if actions else pick_action(feature)
    if action == "show":
        cmd_show(argparse.Namespace(feature=ref))
    elif action == "status":
        cmd_status(argparse.Namespace(feature=ref))
    elif action == "review":
        cmd_review(argparse.Namespace(feature=ref, dry_run=False))
    elif action == "comment":
        cmd_comment(argparse.Namespace(feature=ref))
    elif action == "next":
        cmd_next(argparse.Namespace(feature=ref, pick=False))
    elif action == "approve":
        cmd_approve(argparse.Namespace(feature=ref, pick=False, yes=False))
    elif action in ("complete", "cancel"):
        if confirm("%s #%s" % (action, ref)):
            cmd_feature_transition("done" if action == "complete" else "canceled")(
                argparse.Namespace(feature=ref)
            )
        else:
            print("not %s" % ("completed" if action == "complete" else "canceled"))
    else:
        raise CliError("unknown action %r" % action)


# --- CLI --------------------------------------------------------------------


def feature_arg(parser, required=True, help_text="issue number or title substring"):
    parser.add_argument("feature", nargs=None if required else "?", help=help_text)


def pick_arg(parser, help_text="pick an active feature"):
    parser.add_argument("--pick", action="store_true", help=help_text)


def all_arg(parser, help_text="include terminal features"):
    parser.add_argument("--all", action="store_true", help=help_text)


def build_parser():
    parser = argparse.ArgumentParser(
        prog="sdlc",
        description="Stateless SDLC control plane over GitHub Issues (registry: $SDLC_REPO).",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("list", help="list features")
    all_arg(p, "include closed, done, and canceled")
    p.add_argument("--repo", help="registry repo (default $SDLC_REPO)")
    p.add_argument("--format", choices=("human", "path", "json"), default="human")
    pick_arg(p, "pick one feature and print its number")
    p.set_defaults(fn=cmd_list)

    p = sub.add_parser("show", help="print a feature body and comments")
    feature_arg(p)
    p.set_defaults(fn=cmd_show)

    p = sub.add_parser("status", help="approval and task state of a feature")
    feature_arg(p)
    p.set_defaults(fn=cmd_status)

    p = sub.add_parser("next", help="print the next ready task")
    feature_arg(p, required=False)
    pick_arg(p)
    p.set_defaults(fn=cmd_next)

    p = sub.add_parser("approve", help="record human approval of the design")
    feature_arg(p, required=False)
    p.add_argument("--yes", action="store_true", help="skip the TTY confirmation")
    pick_arg(p)
    p.set_defaults(fn=cmd_approve)

    p = sub.add_parser("new", help="create a feature issue")
    p.add_argument("slug")
    p.add_argument("--repo", required=True, help="code repo the feature belongs to")
    p.add_argument("--title")
    p.set_defaults(fn=cmd_new)

    task = sub.add_parser("task", help="manage task sub-issues")
    task_sub = task.add_subparsers(dest="task_command", required=True)
    p = task_sub.add_parser("add", help="create a task sub-issue")
    feature_arg(p, help_text="feature issue number or title substring")
    p.add_argument("title")
    p.add_argument("--needs", help="comma-separated T-labels or issue numbers")
    p.set_defaults(fn=cmd_task_add)
    for action, help_text in (
        ("start", "mark a task in progress"),
        ("done", "mark a task done and close it"),
        ("cancel", "cancel a task and close it"),
    ):
        p = task_sub.add_parser(action, help=help_text)
        p.add_argument("issue")
        p.set_defaults(fn=cmd_task_transition(action))

    p = sub.add_parser("complete", help="close a feature as done")
    feature_arg(p)
    p.set_defaults(fn=cmd_feature_transition("done"))

    p = sub.add_parser("cancel", help="close a feature as canceled")
    feature_arg(p)
    p.set_defaults(fn=cmd_feature_transition("canceled"))

    p = sub.add_parser("ui", help="pick a feature and an action")
    p.add_argument("items", nargs="*", help="action and/or feature")
    all_arg(p)
    p.add_argument("--repo", help="registry repo (default $SDLC_REPO)")
    p.set_defaults(fn=cmd_ui)

    p = sub.add_parser("review", help="review a feature body in revdiff and post the notes")
    feature_arg(p)
    p.add_argument("--dry-run", action="store_true", help="print the comment instead of posting")
    p.set_defaults(fn=cmd_review)

    p = sub.add_parser("comment", help="comment on a feature in $EDITOR")
    feature_arg(p, required=False)
    p.set_defaults(fn=cmd_comment)

    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        args.fn(args)
    except CliError as exc:
        sys.stderr.write("%s\n" % exc)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
