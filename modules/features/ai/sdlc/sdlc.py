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
from dataclasses import dataclass

TERMINAL = {"completed", "canceled", "duplicate"}
PLAN_LABEL = "plan-approved"
DESIGN_LABEL = "design-approved"

_CONTROL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")


def clean(value):
    return _CONTROL.sub("", value) if isinstance(value, str) else value


@dataclass(frozen=True)
class Task:
    identifier: str
    title: str
    url: str
    state_name: str
    state_type: str
    blocks: tuple = ()
    blocked_by: tuple = ()

    @property
    def done(self):
        return self.state_type in TERMINAL


@dataclass(frozen=True)
class Blocker:
    identifier: str
    title: str
    done: bool


@dataclass
class Dag:
    identifier: str
    title: str
    description: str
    labels: set
    tasks: list

    def __post_init__(self):
        self._by_id = {t.identifier: t for t in self.tasks}

    @classmethod
    def from_issue(cls, parent):
        tasks = []
        for child in parent["children"]["nodes"]:
            _no_trunc(f"{child['identifier']} relations", child["relations"])
            _no_trunc(f"{child['identifier']} inverse-relations", child["inverseRelations"])
            blocks = tuple(
                rel["relatedIssue"]["identifier"]
                for rel in child["relations"]["nodes"]
                if rel["type"] == "blocks" and rel.get("relatedIssue")
            )
            blocked_by = tuple(
                Blocker(
                    identifier=rel["issue"]["identifier"],
                    title=rel["issue"]["title"],
                    done=rel["issue"]["state"]["type"] in TERMINAL,
                )
                for rel in child["inverseRelations"]["nodes"]
                if rel["type"] == "blocks" and rel.get("issue")
            )
            tasks.append(
                Task(
                    identifier=child["identifier"],
                    title=child["title"],
                    url=child.get("url") or "",
                    state_name=child["state"]["name"],
                    state_type=child["state"]["type"],
                    blocks=blocks,
                    blocked_by=blocked_by,
                )
            )
        return cls(
            identifier=parent["identifier"],
            title=parent["title"],
            description=parent.get("description") or "",
            labels={label["name"] for label in parent["labels"]["nodes"]},
            tasks=tasks,
        )

    @property
    def plan_approved(self):
        return PLAN_LABEL in self.labels

    @property
    def design_approved(self):
        return DESIGN_LABEL in self.labels

    def find(self, identifier):
        return self._by_id.get(identifier)

    def workable(self):
        return [
            t for t in self.tasks if not t.done and all(b.done for b in t.blocked_by)
        ]

    def has_cycle(self):
        nodes = {t.identifier for t in self.tasks}
        for t in self.tasks:
            nodes.update(t.blocks)
        adj = {node: [] for node in nodes}
        for t in self.tasks:
            adj[t.identifier].extend(t.blocks)

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

    def render(self):
        done = sum(1 for t in self.tasks if t.done)
        lines = [
            f"{clean(self.identifier)} — {clean(self.title)}",
            f"gates: design-approved={'yes' if self.design_approved else 'no'} "
            f"plan-approved={'yes' if self.plan_approved else 'no'}",
            f"tasks: {done}/{len(self.tasks)} done",
            "",
        ]
        for t in self.tasks:
            mark = "x" if t.done else " "
            lines.append(
                f"- [{mark}] {clean(t.identifier)} {clean(t.title)} ({clean(t.state_name)})"
            )
        edges = sorted((t.identifier, b) for t in self.tasks for b in t.blocks)
        if edges:
            lines.append("")
            lines.append("blocks:")
            for src, dst in edges:
                lines.append(f"  {clean(src)} -> {clean(dst)}")
        return "\n".join(lines)


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
    return Dag.from_issue(parent)


def cmd_next(args):
    dag = load_dag(args.parent)
    if dag.has_cycle():
        print("sdlc: plan has a dependency cycle", file=sys.stderr)
        return 1
    if not dag.plan_approved:
        print("sdlc: plan not approved (add plan-approved label)", file=sys.stderr)
        return 1
    ready = dag.workable()
    if not ready:
        print("sdlc: no workable tasks (blocked or done)", file=sys.stderr)
        return 1
    if args.all:
        for task in ready:
            print(f"{clean(task.identifier)} {clean(task.title)}")
    else:
        task = ready[0]
        print(f"{clean(task.identifier)} {clean(task.title)}")
        if task.url:
            print(clean(task.url))
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
    dag = load_dag(args.parent)
    if dag.has_cycle():
        print("sdlc: plan has a dependency cycle", file=sys.stderr)
        return 1
    text = dag.render()
    print(text)
    if args.post:
        return _post_comment(args.parent, text)
    return 0


def cmd_status(args):
    print(load_dag(args.parent).render())
    return 0


def _bootstrap_feature(feature_id):
    dag = load_dag(feature_id)
    out = [
        f"# {clean(dag.identifier)} — {clean(dag.title)}",
        f"design-approved={'yes' if dag.design_approved else 'no'} "
        f"plan-approved={'yes' if dag.plan_approved else 'no'}",
        "",
        "## Design doc",
        clean(dag.description or "(empty)"),
        "",
        "## Plan",
        dag.render(),
    ]
    print("\n".join(out))


def _bootstrap_task(task, dag):
    node = dag.find(task["identifier"])
    out = [
        f"# {clean(task['identifier'])} — {clean(task['title'])}",
        f"state: {clean(task['state']['name'])} ({clean(task['state']['type'])})",
    ]
    if task.get("url"):
        out.append(f"url: {clean(task['url'])}")
    out += [
        "",
        f"## Feature: {clean(dag.identifier)} — {clean(dag.title)}",
        f"design-approved={'yes' if dag.design_approved else 'no'} "
        f"plan-approved={'yes' if dag.plan_approved else 'no'}",
        "",
        "## Blocked by",
    ]
    if node and node.blocked_by:
        for b in node.blocked_by:
            out.append(
                f"- {clean(b.identifier)} {clean(b.title)} ({'done' if b.done else 'open'})"
            )
    else:
        out.append("- (none)")
    out += [
        "",
        "## Design doc",
        clean(dag.description or "(empty)"),
        "",
        "## Task",
        clean(task.get("description") or "(empty)"),
        "",
        "## Plan",
        dag.render(),
    ]
    print("\n".join(out))


def cmd_bootstrap(args):
    issue = gql(TASK_QUERY, args.issue)
    if issue is None:
        print("sdlc: issue not found", file=sys.stderr)
        return 1
    parent_id = (issue.get("parent") or {}).get("identifier")
    if parent_id:
        _bootstrap_task(issue, load_dag(parent_id))
    else:
        _bootstrap_feature(issue["identifier"])
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