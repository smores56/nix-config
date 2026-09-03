#!/usr/bin/env python3
"""sdlc — file-backed agentic SDLC over the sdlc-state repo.

Full lifecycle: research -> brainstorm -> [grill] -> plan -> build ->
review & fix. A feature dir holds three files:

    design.md   — design doc (human-reviewed; frozen at approval)
    plan.md     — the plan: markdown task list, source of truth
    state.json  — machine state: title, repo, status, approval, claim

plan.md grammar: only `- [ ] T1: Title` task lines parse; everything else
(`> Sam:` review markers, notes, headings) is prose. Approval binds to the
design revision: edits after `sdlc approve` surface as an unapproved-diff
and block `sdlc next` until re-approval. Task re-plans — hand-edits,
reorders, new tasks — are free.
"""

import argparse
import os
import re
import sys

import sdlc_model
import sdlc_state as store

VALID_REPO = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
VALID_SLUG = re.compile(r"^[A-Za-z0-9_-]+$")
DOCS = ("design", "plan")


def _fail(message, code=1):
    print(f"sdlc: {message}", file=sys.stderr)
    return code


def _open(args):
    return store.resolve(store.require_root(), args.feature)


def _load_feature(root, key):
    return store.load(root, key)


def _plan_tasks(feature):
    """Parse plan.md into (tasks, problems); problems are line-anchored."""
    tasks, problems, _ = sdlc_model.parse_plan(feature.get("plan", ""))
    problems += sdlc_model.validate_tasks(tasks)
    return tasks, problems


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


def _commit_doc(root, key, doc):
    store.commit(root, f"{key}: edit {doc}")


def cmd_list(args):
    root = store.require_root()
    statuses = {"active", "done", "canceled"} if args.all else {args.status}
    features = []
    for key in store.list_keys(root):
        try:
            state = store.load(root, key)
        except SystemExit as error:
            print(f"sdlc: skipping {key}: {error}", file=sys.stderr)
            continue
        if state.get("status") not in statuses:
            continue
        if args.repo and args.repo != state.get("repo") and args.repo not in key:
            continue
        state["tasks"], _ = _plan_tasks(state)
        if args.path:
            print(f"{store.feature_dir(root, key)}\t{key}\t{sdlc_model.phase(state)}")
            continue
        features.append(state)
    if not args.path:
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
    print(store.plan_path(root, key))
    return 0


def cmd_path(args):
    root = store.require_root()
    key = _open(args)
    if args.doc == "design" or args.doc is None:
        print(store.design_path(root, key))
    if args.doc == "plan" or args.doc is None:
        print(store.plan_path(root, key))
    return 0


def cmd_edit(args):
    root = store.require_root()
    key = _open(args)
    feature = store.load(root, key)
    blocked = _ensure_mutable(feature, key)
    if blocked is not None:
        return blocked
    doc = args.doc or "design"
    path = store.design_path(root, key) if doc == "design" else store.plan_path(root, key)
    if not os.path.isfile(path):
        return _fail(f"{key}: {doc}.md missing")
    before = open(path).read()
    code = store.run_editor(path)
    if code != 0:
        return _fail(f"editor exited {code}")
    after = open(path).read()
    if after == before:
        print("sdlc: doc unchanged")
        return 0
    _commit_doc(root, key, doc)
    print(f"sdlc: {doc}.md updated — {path}")
    if doc == "plan":
        # Strict save: an invalid plan is a failed edit (file kept, committed).
        feature["plan"] = after
        _, problems = _plan_tasks(feature)
        if problems:
            _report_problems(problems)
            print(f"sdlc: {key}: plan invalid — fix the doc and re-run `sdlc edit {key} plan`", file=sys.stderr)
            return 1
    return 0


def cmd_plan(args):
    root = store.require_root()
    key = _open(args)
    feature = _load_feature(root, key)
    tasks, problems = _plan_tasks(feature)
    if problems:
        _report_problems(problems)
        return 1
    feature["tasks"] = tasks
    print(sdlc_model.render(feature))
    return 0


def cmd_status(args):
    root = store.require_root()
    key = _open(args)
    feature = _load_feature(root, key)
    tasks, problems = _plan_tasks(feature)
    feature["tasks"] = tasks
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
    tasks, problems = _plan_tasks(feature)
    if problems:
        return _fail(f"{key}: plan invalid: {'; '.join(problems)}")
    if not tasks:
        return _fail(f"{key}: plan has no tasks — add tasks before approving")
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
    tasks, problems = _plan_tasks(feature)
    if problems:
        return _fail(f"{key}: plan invalid: {'; '.join(problems)}")
    block = _gate_blocker(feature)
    if block:
        return _fail(f"{key}: {block}")
    ready = sdlc_model.workable(tasks)
    if not ready:
        remaining = [t for t in tasks if not sdlc_model.done(t)]
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
    tasks, problems = _plan_tasks(feature)
    gates = sdlc_model.gate_status(feature)
    diff = "unapproved" if gates["design_changed"] else "clean"
    markers = sdlc_model.open_markers(feature.get("design", "")) + sdlc_model.open_markers(
        feature.get("plan", "")
    )
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
    if markers:
        out.append("")
        out.append("## Open questions (Sam's markers)")
        for marker in markers:
            out.append(f"- {sdlc_model.clean(marker)}")
    if problems:
        out.append("")
        out.append("plan problems: " + "; ".join(problems))
    print("\n".join(out))
    return 1 if problems else 0


def _plan_text(lines):
    """Join parsed lines back to a doc that always ends with a newline."""
    text = "\n".join(lines)
    return text if text.endswith("\n") else text + "\n"


def cmd_task(args):
    root = store.require_root()
    key = _open(args)
    feature = store.load(root, key)
    blocked = _ensure_mutable(feature, key)
    if blocked is not None:
        return blocked
    sub = args.task_cmd
    if sub == "add":
        title = args.title_or_id
        if not title:
            return _fail("task add: title required")
        tasks, problems, lines = sdlc_model.parse_plan(feature.get("plan", ""))
        if problems:
            return _fail(f"{key}: plan invalid: {'; '.join(problems)}")
        needs = [n.strip().upper() for n in (args.needs or "").split(",") if n.strip()]
        known = {t["id"] for t in tasks}
        for need in needs:
            if need not in known:
                return _fail(f"task add: unknown need {need!r} (no such task)")
        tid = store.task_ids({"tasks": tasks})
        new_task = {"id": tid, "title": title, "status": "todo", "needs": needs}
        lines = sdlc_model.append_task_line(lines, new_task)
        store.write_plan(root, key, _plan_text(lines))
        print(f"{tid} {sdlc_model.clean(title)}")
        return 0
    task_id = (args.title_or_id or "").strip().upper()
    if not re.match(r"^T[0-9]+$", task_id):
        return _fail(f"task {sub}: task id required (e.g. T1)")
    tasks, problems, lines = sdlc_model.parse_plan(feature.get("plan", ""))
    if problems:
        return _fail(f"{key}: plan invalid: {'; '.join(problems)}")
    found = next((t for t in tasks if t["id"] == task_id), None)
    if not found:
        return _fail(f"task {sub}: no task {task_id}")
    if sub in ("done", "cancel"):
        target = "done" if sub == "done" else "canceled"
        if found["status"] == target:
            return _fail(f"task {task_id} already {target}")
        if sub == "done" and found["status"] == "canceled":
            return _fail(f"task {task_id} is canceled")
        found["status"] = target
        lines = sdlc_model.replace_task_line(lines, task_id, found)
        store.write_plan(root, key, _plan_text(lines))
        print(f"sdlc: {task_id} {target}")
        return 0
    return _fail(f"unknown task subcommand {sub!r}")


def cmd_diff(args):
    root = store.require_root()
    key = _open(args)
    feature = store.load(root, key)
    approval = feature.get("approval")
    if not approval:
        return _fail(f"{key}: not approved — nothing to diff against")
    rel = os.path.join("features", key, "design.md")
    base = None
    for rev in store.git_log_revs(root, rel):
        if store.git_blob_sha(root, rev, rel) == approval.get("design_sha"):
            base = rev
            break
    if base is None:
        return _fail(f"{key}: approved design revision not found in state history")
    proc = store.git(root, "diff", "--no-color", base, "--", rel, check=False)
    if not proc.stdout.strip():
        print("no changes since approval")
        return 0
    print(proc.stdout.rstrip())
    return 0


def cmd_sync(_args):
    root = store.require_root()
    store.sync(root)
    return 0


def cmd_prune(args):
    root = store.require_root()
    key = _open(args)
    feature = store.load(root, key)
    if feature.get("status") not in ("done", "canceled"):
        return _fail(f"{key}: only terminal features (done/canceled) can be pruned")
    store.prune(root, key)
    print(f"sdlc: pruned {key}")
    return 0


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
    tasks, problems = _plan_tasks(feature)
    if problems:
        return _fail(f"{key}: plan invalid: {'; '.join(problems)}")
    if not tasks:
        return _fail(f"{key}: plan has no tasks — nothing to complete")
    if not gates["approved"]:
        return _fail(f"{key}: not approved — nothing to complete without an approved plan")
    if gates["design_changed"]:
        return _fail(f"{key}: design changed since approval — re-approve before completing")
    if not all(sdlc_model.done(t) for t in tasks):
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

    p = sub.add_parser("list", help="list features with phase and claim")
    p.add_argument("--all", action="store_true", help="include done and canceled features")
    p.add_argument("--status", choices=["active", "done", "canceled"], default="active", help="status filter (default: active)")
    p.add_argument("--repo", help="only features whose key contains this owner/repo")
    p.add_argument("--path", action="store_true", help="machine format: path\\tkey\\tphase per line")
    p.set_defaults(func=cmd_list)

    p = sub.add_parser("new", help="create a feature (design.md + plan.md + state)")
    p.add_argument("slug", help="kebab-case feature slug")
    p.add_argument("--repo", help="owner/repo the work lands in (default: cwd origin)")
    p.add_argument("--title", help="human title (default: slug)")
    p.set_defaults(func=cmd_new)

    p = sub.add_parser("path", help="print design.md / plan.md paths")
    p.add_argument("feature")
    p.add_argument("doc", nargs="?", choices=DOCS, help="design or plan (default: both)")
    p.set_defaults(func=cmd_path)

    p = sub.add_parser("edit", help="open a doc in $EDITOR, commit, validate plan")
    p.add_argument("feature")
    p.add_argument("doc", nargs="?", choices=DOCS, default="design", help="design or plan (default: design)")
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

    p = sub.add_parser("diff", help="show design.md changes since approval")
    p.add_argument("feature")
    p.set_defaults(func=cmd_diff)

    p = sub.add_parser("sync", help="pull remote state changes and push local ones")
    p.set_defaults(func=cmd_sync)

    p = sub.add_parser("prune", help="delete a terminal (done/canceled) feature")
    p.add_argument("feature")
    p.set_defaults(func=cmd_prune)

    args = parser.parse_args()
    sys.exit(args.func(args))


if __name__ == "__main__":
    main()
