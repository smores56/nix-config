"""sdlc model: task DAG, gate state, phases, rendering. Pure logic — no I/O."""

import hashlib
import re

TERMINAL = {"done", "canceled"}

PLAN_VALID_TASK_STATUSES = {"todo", "done", "canceled"}

_CONTROL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")


def clean(value):
    """Strip control characters from untrusted text before rendering."""
    return _CONTROL.sub("", value) if isinstance(value, str) else value


# plan.md grammar: only task-list lines parse; everything else is prose.
#   - [ ] T1: Title
#   - [x] T1: Title
#   - [ ] T1: Title (needs: T2, T3)
#   - [x] T1: Title (needs: T2) (canceled)
TASK_LINE = re.compile(r"^\- \[( |x)\] (T[0-9]+): (.*?)( \(needs: [^)]+\))?( \(canceled\))?$")
MARKER_LINE = re.compile(r"^\s*>\s*Sam:\s*(.*)$")


def parse_plan(text):
    """Parse plan.md text into (tasks, problems, lines).

    Tasks carry file order plus a `line` index into `lines` so mutations can
    rewrite a single line and leave prose (notes, markers) untouched.
    Problems are line-anchored and only fire on task-shaped lines that do not
    parse; semantic validation is separate (validate_tasks).
    """
    lines = text.split("\n")
    tasks = []
    problems = []
    for idx, line in enumerate(lines):
        match = TASK_LINE.match(line.rstrip())
        if match:
            status = "done" if match.group(1) == "x" else "todo"
            tid = match.group(2)
            title = (match.group(3) or "").strip()
            needs = (
                [n.strip().upper() for n in match.group(4)[len(" (needs: ") : -1].split(",") if n.strip()]
                if match.group(4)
                else []
            )
            if match.group(5):
                status = "canceled"
            if not title:
                problems.append(f"line {idx + 1}: task {tid} has no title")
                continue
            tasks.append({"id": tid, "title": title, "status": status, "needs": needs, "line": idx})
        elif line.startswith("- ["):
            problems.append(f"line {idx + 1}: malformed task line: {line.strip()[:60]}")
    return tasks, problems, lines


def task_line(task):
    """Render a task dict back to a canonical plan.md line."""
    mark = "[x]" if task["status"] in ("done", "canceled") else "[ ]"
    needs = task.get("needs", [])
    suffix = f" (needs: {', '.join(needs)})" if needs else ""
    canceled = " (canceled)" if task["status"] == "canceled" else ""
    return f"- {mark} {task['id']}: {task['title']}{suffix}{canceled}"


def replace_task_line(lines, task_id, new_task):
    """Return lines with the task's line rewritten (prose untouched)."""
    out = list(lines)
    for idx, line in enumerate(out):
        match = TASK_LINE.match(line.rstrip())
        if match and match.group(2) == task_id:
            out[idx] = task_line(new_task)
            return out
    raise ValueError(f"no task line for {task_id}")


def append_task_line(lines, task):
    """Insert a task line after the last task line (or at end)."""
    out = list(lines)
    last = -1
    for idx, line in enumerate(out):
        if TASK_LINE.match(line.rstrip()):
            last = idx
    new = task_line(task)
    if last >= 0:
        out.insert(last + 1, new)
    else:
        if out and out[-1] != "":
            out.append("")
        out.append(new)
    return out


def open_markers(text):
    """Human review markers (`> Sam: ...`) addressed to the agent."""
    return [m.group(1).strip() for m in map(MARKER_LINE.match, text.splitlines()) if m]


def done(task):
    return task["status"] in TERMINAL


def design_sha(content):
    # Change marker for the design-frozen gate; not a security primitive.
    return hashlib.sha1(content.encode("utf-8")).hexdigest()  # noqa: S324


def has_cycle(tasks):
    """True when the needs-graph contains a cycle (needs = must finish first)."""
    state = {}

    def dfs(task_id):
        state[task_id] = 1
        for nxt in needs_of(tasks, task_id):
            if nxt not in state:
                if dfs(nxt):
                    return True
            elif state[nxt] == 1:
                return True
        state[task_id] = 2
        return False

    return any(t not in state and dfs(t) for t in ids(tasks))


def needs_of(tasks, task_id):
    for t in tasks:
        if t["id"] == task_id:
            return t.get("needs", [])
    return []


def ids(tasks):
    return [t["id"] for t in tasks]


def validate_tasks(tasks):
    """Return a list of plan problems; empty means the plan is valid.

    Order-independent: needs may reference tasks that appear later.
    """
    problems = []
    all_ids = ids(tasks)
    seen = set()
    for t in tasks:
        if t["id"] in seen:
            problems.append(f"duplicate task id: {t['id']}")
        seen.add(t["id"])
        if t["status"] not in PLAN_VALID_TASK_STATUSES:
            problems.append(f"{t['id']}: invalid status {t['status']!r}")
        for need in t.get("needs", []):
            if need not in all_ids:
                problems.append(f"{t['id']}: unknown need {need!r}")
    if has_cycle(tasks):
        problems.append("dependency cycle")
    return problems


def workable(tasks):
    by_id = {t["id"]: t for t in tasks}
    return [
        t for t in tasks if not done(t) and all(done(by_id[n]) for n in t.get("needs", []) if n in by_id)
    ]


def phase(feature):
    status = feature.get("status", "active")
    if status == "done":
        return "done"
    if status == "canceled":
        return "canceled"
    tasks = feature.get("tasks", [])
    if not feature.get("approval"):
        return "design" if not tasks else "plan review"
    return "building" if any(not done(t) for t in tasks) else "finishing"


def design_diff(feature):
    """Approved design_sha when the design changed post-approval, else None."""
    approval = feature.get("approval")
    if not approval:
        return None
    approved_sha = approval.get("design_sha")
    if approved_sha and approved_sha != design_sha(feature.get("design", "")):
        return approved_sha
    return None


def gate_status(feature):
    """Structured gate state for rendering and hard blocks."""
    return {
        "active": feature.get("status", "active") == "active",
        "approved": bool(feature.get("approval")),
        "design_changed": design_diff(feature) is not None,
    }


def render_tasks(tasks):
    lines = []
    for t in tasks:
        mark = "x" if done(t) else " "
        needs = t.get("needs", [])
        suffix = f" (needs: {', '.join(clean(n) for n in needs)})" if needs else ""
        lines.append(f"- [{mark}] {clean(t['id'])} {clean(t['title'])}{suffix}")
    return lines


def render(feature):
    tasks = feature.get("tasks", [])
    gates = gate_status(feature)
    claim = feature.get("claim")
    total = len(tasks)
    finished = sum(1 for t in tasks if done(t))
    diff = "unapproved-diff" if gates["design_changed"] else "clean"
    lines = [
        f"{feature['key']} — {clean(feature.get('title', ''))}",
        f"repo: {clean(feature.get('repo', ''))}",
        f"phase: {phase(feature)}",
        f"gates: approved={'yes' if gates['approved'] else 'no'} design-diff={diff}",
        f"claim: {clean((claim or {}).get('by', 'none'))}",
        f"tasks: {finished}/{total} done",
        "",
    ]
    lines += render_tasks(tasks)
    return "\n".join(lines)


def render_list(features):
    rows = [
        (f["key"], f.get("title", ""), phase(f), (f.get("claim") or {}).get("by", ""))
        for f in features
    ]
    if not rows:
        return "no active features"
    id_width = max(len(r[0]) for r in rows)
    out = []
    for key, title, ph, claim in rows:
        title = clean(title)
        claim = clean(claim)
        title = title if len(title) <= 48 else title[:47] + "…"
        out.append(f"{key:<{id_width}}  {title:<48}  {ph:<11}  {claim}")
    return "\n".join(out)
