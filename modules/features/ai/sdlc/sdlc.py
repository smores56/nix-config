#!/usr/bin/env python3
"""sdlc — Linear-driven SDLC. Linear is the single source of truth."""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

TERMINAL = {"completed", "canceled", "duplicate"}
PLAN_LABEL = "plan-approved"
DESIGN_LABEL = "design-approved"

_CONTROL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")


def clean(value):
    return _CONTROL.sub("", value) if isinstance(value, str) else value


DAG_QUERY = """
query($id: String!) {
  issue(id: $id) {
    identifier
    title
    description
    state { name type }
    labels(first: 100) {
      nodes { name }
      pageInfo { hasNextPage }
    }
    children(first: 200) {
      nodes {
        id
        identifier
        title
        url
        state { name type }
        relations(first: 200) {
          nodes {
            type
            relatedIssue { identifier }
          }
          pageInfo { hasNextPage }
        }
        inverseRelations(first: 200) {
          nodes {
            type
            issue { identifier title state { name type } }
          }
          pageInfo { hasNextPage }
        }
      }
      pageInfo { hasNextPage }
    }
  }
}
"""

TASK_QUERY = """
query($id: String!) {
  issue(id: $id) {
    identifier
    title
    description
    url
    state { name type }
    parent { identifier }
  }
}
"""


def gql(query, issue_id):
    if shutil.which("linear") is None:
        sys.exit("sdlc: `linear` not on PATH")
    proc = subprocess.run(
        ["linear", "api", "--variable", f"id={issue_id}"],
        input=query,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        sys.exit(f"sdlc: linear api failed: {proc.stderr.strip()}")
    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError:
        sys.exit("sdlc: linear api returned non-JSON output")
    if data.get("errors"):
        sys.exit(f"sdlc: graphql: {data['errors'][0]['message']}")
    return (data.get("data") or {}).get("issue")


def _no_trunc(name, conn):
    if (conn.get("pageInfo") or {}).get("hasNextPage"):
        sys.exit(f"sdlc: {name} exceeds the fetch limit — split the feature")


def load_dag(parent_id):
    parent = gql(DAG_QUERY, parent_id)
    if parent is None:
        sys.exit("sdlc: issue not found")
    _no_trunc("children", parent["children"])
    _no_trunc("labels", parent["labels"])
    children = parent["children"]["nodes"]
    blockers = {}
    for child in children:
        _no_trunc(f"{child['identifier']} relations", child["relations"])
        _no_trunc(f"{child['identifier']} inverse-relations", child["inverseRelations"])
        blockers[child["identifier"]] = [
            {
                "identifier": rel["issue"]["identifier"],
                "title": rel["issue"]["title"],
                "done": rel["issue"]["state"]["type"] in TERMINAL,
            }
            for rel in child["inverseRelations"]["nodes"]
            if rel["type"] == "blocks" and rel.get("issue")
        ]
    return parent, children, blockers


def labels_of(parent):
    return {label["name"] for label in parent["labels"]["nodes"]}


def block_edges(children):
    edges = []
    for child in children:
        for rel in child["relations"]["nodes"]:
            if rel["type"] == "blocks" and rel.get("relatedIssue"):
                edges.append((child["identifier"], rel["relatedIssue"]["identifier"]))
    return edges


def has_cycle(children):
    nodes = set()
    for src, dst in block_edges(children):
        nodes.add(src)
        nodes.add(dst)
    adj = {node: [] for node in nodes}
    for src, dst in block_edges(children):
        adj[src].append(dst)

    state = {}

    def dfs(node):
        state[node] = 1
        for nxt in adj[node]:
            if nxt not in state:
                if dfs(nxt):
                    return True
            elif state[nxt] == 1:
                return True
        state[node] = 2
        return False

    return any(node not in state and dfs(node) for node in nodes)


def render_plan(parent, children, blockers):
    labels = labels_of(parent)
    done = sum(1 for c in children if c["state"]["type"] in TERMINAL)
    lines = [
        f"{clean(parent['identifier'])} — {clean(parent['title'])}",
        f"gates: design-approved={'yes' if DESIGN_LABEL in labels else 'no'} "
        f"plan-approved={'yes' if PLAN_LABEL in labels else 'no'}",
        f"tasks: {done}/{len(children)} done",
        "",
    ]
    for child in children:
        mark = "x" if child["state"]["type"] in TERMINAL else " "
        lines.append(
            f"- [{mark}] {clean(child['identifier'])} {clean(child['title'])} "
            f"({clean(child['state']['name'])})"
        )
    edges = block_edges(children)
    if edges:
        lines.append("")
        lines.append("blocks:")
        for src, dst in sorted(edges):
            lines.append(f"  {clean(src)} -> {clean(dst)}")
    return "\n".join(lines)


def workable(parent, children, blockers):
    if PLAN_LABEL not in labels_of(parent):
        return None, "plan not approved (add plan-approved label)"
    open_ = [c for c in children if c["state"]["type"] not in TERMINAL]
    ready = [c for c in open_ if all(b["done"] for b in blockers[c["identifier"]])]
    if not ready:
        return None, "no workable tasks (blocked or done)"
    return ready, None


def cmd_next(args):
    parent, children, blockers = load_dag(args.parent)
    if has_cycle(children):
        print("sdlc: plan has a dependency cycle", file=sys.stderr)
        return 1
    ready, err = workable(parent, children, blockers)
    if err:
        print(f"sdlc: {err}", file=sys.stderr)
        return 1
    if args.all:
        for task in ready:
            print(f"{clean(task['identifier'])} {clean(task['title'])}")
    else:
        task = ready[0]
        print(f"{clean(task['identifier'])} {clean(task['title'])}")
        if task.get("url"):
            print(clean(task["url"]))
    return 0


def _post_comment(parent_id, text):
    path = None
    try:
        with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as f:
            f.write(text)
            path = f.name
        proc = subprocess.run(
            ["linear", "issue", "comment", "add", parent_id, "--body-file", path],
            capture_output=True,
            text=True,
        )
        if proc.returncode != 0:
            print(f"sdlc: posting plan failed: {proc.stderr.strip()}", file=sys.stderr)
            return 1
    finally:
        if path:
            os.unlink(path)
    print(f"\nposted plan to {parent_id}")
    return 0


def cmd_plan(args):
    parent, children, blockers = load_dag(args.parent)
    if has_cycle(children):
        print("sdlc: plan has a dependency cycle", file=sys.stderr)
        return 1
    text = render_plan(parent, children, blockers)
    print(text)
    if args.post:
        return _post_comment(args.parent, text)
    return 0


def cmd_status(args):
    parent, children, blockers = load_dag(args.parent)
    print(render_plan(parent, children, blockers))
    return 0


def _bootstrap_feature(feature):
    parent, children, blockers = load_dag(feature["identifier"])
    labels = labels_of(parent)
    out = [
        f"# {clean(parent['identifier'])} — {clean(parent['title'])}",
        f"design-approved={'yes' if DESIGN_LABEL in labels else 'no'} "
        f"plan-approved={'yes' if PLAN_LABEL in labels else 'no'}",
        "",
        "## Design doc",
        clean(parent.get("description") or "(empty)"),
        "",
        "## Plan",
        render_plan(parent, children, blockers),
    ]
    print("\n".join(out))


def _bootstrap_task(task, parent_id):
    parent, children, blockers = load_dag(parent_id)
    labels = labels_of(parent)
    task_blockers = blockers.get(task["identifier"], [])

    out = [
        f"# {clean(task['identifier'])} — {clean(task['title'])}",
        f"state: {clean(task['state']['name'])} ({clean(task['state']['type'])})",
    ]
    if task.get("url"):
        out.append(f"url: {clean(task['url'])}")
    out += [
        "",
        f"## Feature: {clean(parent['identifier'])} — {clean(parent['title'])}",
        f"design-approved={'yes' if DESIGN_LABEL in labels else 'no'} "
        f"plan-approved={'yes' if PLAN_LABEL in labels else 'no'}",
        "",
        "## Blocked by",
    ]
    if task_blockers:
        for b in task_blockers:
            out.append(
                f"- {clean(b['identifier'])} {clean(b['title'])} "
                f"({'done' if b['done'] else 'open'})"
            )
    else:
        out.append("- (none)")
    out += [
        "",
        "## Design doc",
        clean(parent.get("description") or "(empty)"),
        "",
        "## Task",
        clean(task.get("description") or "(empty)"),
        "",
        "## Plan",
        render_plan(parent, children, blockers),
    ]
    print("\n".join(out))


def cmd_bootstrap(args):
    issue = gql(TASK_QUERY, args.issue)
    if issue is None:
        print("sdlc: issue not found", file=sys.stderr)
        return 1
    parent_id = (issue.get("parent") or {}).get("identifier")
    if parent_id:
        _bootstrap_task(issue, parent_id)
    else:
        _bootstrap_feature(issue)
    return 0


def main():
    parser = argparse.ArgumentParser(prog="sdlc", description="Linear-driven agentic SDLC")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("plan", help="validate DAG and render the lean plan")
    p.add_argument("parent")
    p.add_argument("--post", action="store_true", help="also post the plan as a comment")
    p.set_defaults(func=cmd_plan)

    p = sub.add_parser("next", help="print the next workable task, or hard-block")
    p.add_argument("parent")
    p.add_argument("--all", action="store_true", help="list all workable tasks")
    p.set_defaults(func=cmd_next)

    p = sub.add_parser("status", help="render the DAG and gate state")
    p.add_argument("parent")
    p.set_defaults(func=cmd_status)

    p = sub.add_parser("bootstrap", help="print a session brief for a feature or task")
    p.add_argument("issue")
    p.set_defaults(func=cmd_bootstrap)

    args = parser.parse_args()
    sys.exit(args.func(args))


if __name__ == "__main__":
    main()