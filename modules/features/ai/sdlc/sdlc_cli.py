#!/usr/bin/env python3
"""sdlc — file-backed agentic SDLC over the sdlc-state repo.

Full lifecycle: research -> brainstorm -> [grill] -> plan -> build ->
review & fix. The design doc lives at
features/<owner>--<repo>--<slug>/design.md; tasks and gate state live in
state.json beside it. Approval binds to the design revision
(design-frozen-at-approval): edits after `sdlc approve` surface as an
unapproved-diff and block `sdlc next` until re-approval. Task-level
re-plans stay free.
"""

import argparse
import os
import re
import sys

import sdlc_model
import sdlc_state as store

VALID_REPO = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
VALID_SLUG = re.compile(r"^[A-Za-z0-9_-]+$")


def _fail(message, code=1):
    print(f"sdlc: {message}", file=sys.stderr)
    return code


def _open(args):
    return store.resolve(store.require_root(), args.feature)


def _load_feature(root, key):
    return store.load(root, key)


def _gate_blocker(feature):
    """Message when the feature is not buildable, else None."""
    gates = sdlc_model.gate_status(feature)
    if not gates["active"]:
        return f"feature is {feature['status']}"
    if not gates["approved"]:
        return "plan not approved — review with `sdlc plan`, then run `sdlc approve`"
    if gates["design_changed"]:
        return "design changed since approval (unapproved-diff) — re-approve after review"
    return None


def _ensure_mutable(feature, key):
    """Refuse mutations on terminal features or features claimed elsewhere."""
    if feature.get("status") != "active":
        return _fail(f"{key}: feature is {feature['status']}")
    claim = feature.get("claim")
    if claim and claim.get("by") != store.who():
        return _fail(f"{key}: claimed by {claim['by']} — only the claimer may mutate")
    return None


def _report_problems(problems):
    for p in problems:
        print(f"sdlc: plan problem: {p}", file=sys.stderr)


def cmd_list(_args):
    root = store.require_root()
    features = []
    for key in store.list_keys(root):
        try:
            state = store.load(root, key)
        except SystemExit as error:
            print(f"sdlc: skipping {key}: {error}", file=sys.stderr)
            continue
        if state.get("status") == "active":
            features.append(state)
    print(sdlc_model.render_list(features))
    return 0


def cmd_new(args):
    root = store.require_root()
    repo = args.repo or store.repo_from_cwd()
    if not repo:
        return _fail("cannot detect repo from cwd origin; pass --repo owner/repo")
    if not VALID_REPO.match(repo):
        return _fail(f"invalid repo {repo!r} (expected owner/repo)")
    if not VALID_SLUG.match(args.slug):
        return _fail(f"invalid slug {args.slug!r} (kebab-case)")
    key = f"{repo.replace('/', '--')}--{args.slug}"
    title = args.title or args.slug
    store.create(root, key, repo, title)
    print(key)
    print(store.design_path(root, key))
    return 0


def cmd_edit(args):
    root = store.require_root()
    key = _open(args)
    feature = store.load(root, key)
    blocked = _ensure_mutable(feature, key)
    if blocked is not None:
        return blocked
    path = store.design_path(root, key)
    if not os.path.isfile(path):
        return _fail(f"{key}: design.md missing")
    before = open(path).read()
    code = store.run_editor(path)
    if code != 0:
        return _fail(f"editor exited {code}")
    after = open(path).read()
    if after == before:
        print("sdlc: design unchanged")
        return 0
    store.commit(root, f"{key}: edit design")
    print(f"sdlc: design updated — {path}")
    return 0


def cmd_plan(args):
    root = store.require_root()
    key = _open(args)
    feature = _load_feature(root, key)
    problems = sdlc_model.validate_tasks(feature.get("tasks", []))
    if problems:
        _report_problems(problems)
        return 1
    print(sdlc_model.render(feature))
    return 0


def cmd_status(args):
    root = store.require_root()
    key = _open(args)
    feature = _load_feature(root, key)
    problems = sdlc_model.validate_tasks(feature.get("tasks", []))
    print(sdlc_model.render(feature))
    if problems:
        _report_problems(problems)
        return 1
    return 0


def cmd_approve(args):
    root = store.require_root()
    key = _open(args)
    feature = store.load(root, key)
    blocked = _ensure_mutable(feature, key)
    if blocked is not None:
        return blocked
    if not feature.get("design", "").strip():
        return _fail(f"{key}: design.md is empty — write the design first")
    if not feature.get("tasks"):
        return _fail(f"{key}: plan has no tasks — add tasks before approving")
    problems = sdlc_model.validate_tasks(feature["tasks"])
    if problems:
        return _fail(f"{key}: plan invalid: {'; '.join(problems)}")
    feature["approval"] = {
        "at": store.now(),
        "by": store.who(),
        "design_sha": sdlc_model.design_sha(feature.get("design", "")),
    }
    store.save(root, key, feature)
    print(f"sdlc: approved {key} (design frozen at this revision)")
    return 0


def cmd_next(args):
    root = store.require_root()
    key = _open(args)
    feature = _load_feature(root, key)
    problems = sdlc_model.validate_tasks(feature.get("tasks", []))
    if problems:
        return _fail(f"{key}: plan invalid: {'; '.join(problems)}")
    block = _gate_blocker(feature)
    if block:
        return _fail(f"{key}: {block}")
    ready = sdlc_model.workable(feature["tasks"])
    if not ready:
        remaining = [t for t in feature["tasks"] if not sdlc_model.done(t)]
        if not remaining:
            return _fail(f"{key}: all tasks terminal — run `sdlc complete {key}`")
        return _fail(f"{key}: no workable tasks (blocked)")
    if args.all:
        for t in ready:
            print(f"{t['id']} {sdlc_model.clean(t['title'])}")
    else:
        print(f"{ready[0]['id']} {sdlc_model.clean(ready[0]['title'])}")
    return 0


def cmd_bootstrap(args):
    root = store.require_root()
    key = _open(args)
    feature = _load_feature(root, key)
    tasks = feature.get("tasks", [])
    problems = sdlc_model.validate_tasks(tasks)
    gates = sdlc_model.gate_status(feature)
    diff = "unapproved" if gates["design_changed"] else "clean"
    out = [
        f"# {key} — {sdlc_model.clean(feature.get('title', ''))}",
        f"repo: {sdlc_model.clean(feature.get('repo', ''))}",
        f"phase: {sdlc_model.phase(feature)}",
        f"gates: approved={'yes' if gates['approved'] else 'no'} design-diff={diff}",
        f"claim: {sdlc_model.clean((feature.get('claim') or {}).get('by', 'none'))}",
        "",
        "## Design doc",
        sdlc_model.clean(feature.get("design", "").strip() or "(empty)"),
        "",
        "## Plan",
    ]
    out += sdlc_model.render_tasks(tasks)
    if problems:
        out.append("")
        out.append("plan problems: " + "; ".join(problems))
    print("\n".join(out))
    return 1 if problems else 0


def cmd_task(args):
    root = store.require_root()
    key = _open(args)
    feature = store.load(root, key)
    blocked = _ensure_mutable(feature, key)
    if blocked is not None:
        return blocked
    tasks = feature.setdefault("tasks", [])
    sub = args.task_cmd
    if sub == "add":
        title = args.title_or_id
        if not title:
            return _fail("task add: title required")
        needs = [n.strip().upper() for n in (args.needs or "").split(",") if n.strip()]
        tid = store.task_ids(feature)
        tasks.append({"id": tid, "title": title, "status": "todo", "needs": needs})
        store.save(root, key, feature)
        print(f"{tid} {sdlc_model.clean(title)}")
        return 0
    task_id = args.title_or_id
    if not re.match(r"^T[0-9]+$", task_id or ""):
        return _fail(f"task {sub}: task id required (e.g. T1)")
    found = next((t for t in tasks if t["id"] == task_id), None)
    if not found:
        return _fail(f"task {sub}: no task {task_id}")
    if sub in ("done", "cancel"):
        target = "done" if sub == "done" else "canceled"
        if found["status"] == target:
            return _fail(f"task {task_id} already {target}")
        found["status"] = target
        store.save(root, key, feature)
        print(f"sdlc: {task_id} {target}")
        return 0
    return _fail(f"unknown task subcommand {sub!r}")


def cmd_claim(args):
    root = store.require_root()
    key = _open(args)
    return store.claim(root, key, release=args.release)


def cmd_complete(args):
    root = store.require_root()
    key = _open(args)
    feature = store.load(root, key)
    blocked = _ensure_mutable(feature, key)
    if blocked is not None:
        return blocked
    gates = sdlc_model.gate_status(feature)
    if not feature.get("tasks"):
        return _fail(f"{key}: plan has no tasks — nothing to complete")
    if not gates["approved"]:
        return _fail(f"{key}: not approved — nothing to complete without an approved plan")
    if gates["design_changed"]:
        return _fail(f"{key}: design changed since approval — re-approve before completing")
    if not all(sdlc_model.done(t) for t in feature["tasks"]):
        return _fail(f"{key}: tasks remain — finish or cancel them first")
    feature["status"] = "done"
    store.save(root, key, feature)
    print(f"sdlc: completed {key}")
    return 0


def cmd_cancel(args):
    root = store.require_root()
    key = _open(args)
    feature = store.load(root, key)
    if feature.get("status") == "done":
        return _fail(f"{key}: already done — cancel only applies to active features")
    if feature.get("status") == "canceled":
        return _fail(f"{key}: already canceled")
    blocked = _ensure_mutable(feature, key)
    if blocked is not None:
        return blocked
    feature["status"] = "canceled"
    store.save(root, key, feature)
    print(f"sdlc: canceled {key}")
    return 0


def main():
    parser = argparse.ArgumentParser(prog="sdlc", description="file-backed agentic SDLC")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("list", help="list active features with phase and claim")
    p.set_defaults(func=cmd_list)

    p = sub.add_parser("new", help="create a feature (design.md + empty plan)")
    p.add_argument("slug", help="kebab-case feature slug")
    p.add_argument("--repo", help="owner/repo the work lands in (default: cwd origin)")
    p.add_argument("--title", help="human title (default: slug)")
    p.set_defaults(func=cmd_new)

    p = sub.add_parser("edit", help="open design.md in $EDITOR, then commit")
    p.add_argument("feature")
    p.set_defaults(func=cmd_edit)

    p = sub.add_parser("plan", help="validate the plan and render it for review")
    p.add_argument("feature")
    p.set_defaults(func=cmd_plan)

    p = sub.add_parser("status", help="render feature state (tasks, gates, diff)")
    p.add_argument("feature")
    p.set_defaults(func=cmd_status)

    p = sub.add_parser("approve", help="approve current design+plan (human gate)")
    p.add_argument("feature")
    p.set_defaults(func=cmd_approve)

    p = sub.add_parser("next", help="print the next workable task, or the blocker")
    p.add_argument("feature")
    p.add_argument("--all", action="store_true", help="list all workable tasks")
    p.set_defaults(func=cmd_next)

    p = sub.add_parser("bootstrap", help="print a session brief for a feature")
    p.add_argument("feature")
    p.set_defaults(func=cmd_bootstrap)

    p = sub.add_parser("task", help="task subcommands (add|done|cancel)")
    p.add_argument("feature")
    p.add_argument("task_cmd", choices=["add", "done", "cancel"])
    p.add_argument("title_or_id", nargs="?", help="title (add) or task id (done/cancel)")
    p.add_argument("--needs", help="comma-separated task ids that must finish first (add)")
    p.set_defaults(func=cmd_task)

    p = sub.add_parser("claim", help="claim a feature (parallel-session guard)")
    p.add_argument("feature")
    p.add_argument("--release", action="store_true", help="release the claim")
    p.set_defaults(func=cmd_claim)

    p = sub.add_parser("complete", help="mark a finished feature done")
    p.add_argument("feature")
    p.set_defaults(func=cmd_complete)

    p = sub.add_parser("cancel", help="cancel a feature")
    p.add_argument("feature")
    p.set_defaults(func=cmd_cancel)

    args = parser.parse_args()
    sys.exit(args.func(args))


if __name__ == "__main__":
    main()
