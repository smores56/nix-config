"""Tests for the stateless sdlc CLI.

Written before implementation (red first). A fake `gh` on PATH records every
call and serves canned JSON, so nothing here needs a network or the real
registry. The design hash fixtures pin the T1 canonicalization rules.
"""

import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
MODULE_DIR = os.path.join(HERE, "..", "modules", "features", "ai", "sdlc")
CLI = os.path.join(MODULE_DIR, "sdlc_issues.py")

sys.path.insert(0, MODULE_DIR)
import sdlc_issues  # noqa: E402

DESIGN = (
    "## Problem\n\n"
    "Features drift from the approved design and merged code.\n\n"
    "## Design\n\n"
    "Use GitHub issues.\n\n"
    "### Principles\n\n"
    "1. One issue per feature.\n\n"
    "## Plan\n\n"
    "- [ ] T1: Build\n"
)
DESIGN_SHA = "a7c00c28e002380560f62e5ddc98968e2b93784ce57a4fc79152353d284bffcc"
COMMENT_AT = "2026-10-20T12:00:00Z"

FAKE_GH = '''#!{python}
import json, os, sys

state = os.environ["FAKE_GH_STATE"]
args = sys.argv[1:]
with open(os.path.join(state, "calls.jsonl"), "a") as fh:
    fh.write(json.dumps(args) + "\\n")

def read(name):
    path = os.path.join(state, name)
    if not os.path.exists(path):
        sys.stderr.write("fake gh: no canned response for %s\\n" % name)
        sys.exit(3)
    with open(path) as fh:
        return fh.read()

if args[:2] == ["issue", "list"]:
    sys.stdout.write(read("list.json"))
elif args[:2] == ["issue", "view"]:
    sys.stdout.write(read("issue-%s.json" % args[2]))
elif args[:2] == ["issue", "create"]:
    sys.stdout.write(read("create_url.txt"))
elif args[:2] in (["issue", "edit"], ["issue", "comment"], ["issue", "close"]):
    if args[:2] == ["issue", "comment"] and "--body-file" in args:
        with open(os.path.join(state, "last-comment.md"), "w") as fh:
            fh.write(sys.stdin.read())
    sys.stdout.write("")
elif args[:2] == ["api", "graphql"]:
    number = None
    for arg in args:
        if arg.startswith("number="):
            number = int(arg.split("=", 1)[1])
    feature = json.loads(read("issue-%d.json" % number))
    def task_node(node):
        path = os.path.join(state, "issue-%d.json" % node["number"])
        if os.path.exists(path):
            with open(path) as fh:
                return json.load(fh)
        return node
    subs = []
    for node in (feature.get("subIssues") or {}).get("nodes", []):
        task = task_node(node)
        subs.append({
            "number": node["number"],
            "title": node.get("title"),
            "state": node.get("state"),
            "labels": {"nodes": task.get("labels", [])},
            "blockedBy": task.get("blockedBy", {"nodes": []}),
        })
    payload = {"data": {"repository": {"issue": {
        "number": feature["number"],
        "title": feature["title"],
        "body": feature.get("body", ""),
        "state": feature["state"],
        "url": feature.get("url"),
        "labels": {"nodes": feature.get("labels", [])},
        "comments": {"nodes": feature.get("comments", [])},
        "subIssues": {"nodes": subs},
    }}}}
    sys.stdout.write(json.dumps(payload))
else:
    sys.stderr.write("fake gh: unexpected args %r\\n" % (args,))
    sys.exit(2)
'''

FAKE_TUICR = '''#!{python}
import json, os, sys

state = os.environ["FAKE_GH_STATE"]
args = sys.argv[1:]
with open(os.path.join(state, "tuicr.jsonl"), "a") as fh:
    fh.write(json.dumps(args) + "\\n")
if "--file" in args:
    with open(args[args.index("--file") + 1]) as fh:
        source = fh.read()
    with open(os.path.join(state, "reviewed-body.md"), "w") as fh:
        fh.write(source)
path = os.path.join(state, "tuicr-export.md")
if os.path.exists(path):
    with open(path) as fh:
        sys.stdout.write(fh.read())
'''

FAKE_TV = '''#!{python}
import json, os, sys

state = os.environ["FAKE_GH_STATE"]
args = sys.argv[1:]
with open(os.path.join(state, "tv.jsonl"), "a") as fh:
    fh.write(json.dumps(args) + "\\n")
if "sdlc-features" in args:
    with open(os.path.join(state, "tv-feature.txt")) as fh:
        sys.stdout.write(fh.read().strip() + "\\n")
    sys.exit(0)
if "--source-command" in args:
    source = args[args.index("--source-command") + 1]
    if source.startswith("cat "):
        with open(source[4:].strip("'")) as fh:
            sys.stdout.write(fh.read().splitlines()[0] + "\\n")
        sys.exit(0)
sys.exit(1)
'''

EXPORT = (
    "I reviewed your code and have the following comments. Please address them.\n\n"
    "1. `body.md:7` - Make this a link.\n"
    "2. `body.md:13-15` - Split the plan.\n"
)

TYPED_EXPORT = (
    "## Session: body.md@main/worktree\n\n"
    "1. **[ISSUE]** `body.md:7` - Typed note.\n"
    "2. **[SUGGESTION]** `body.md:13-15` (commit abc1234) - Range note.\n"
)


def label(name):
    return {"name": name}


def comment(author, body, at=COMMENT_AT):
    return {"author": {"login": author}, "body": body, "createdAt": at}


def nodes(items):
    return {"nodes": list(items), "totalCount": len(items)}


def sub(number, title, state="OPEN"):
    return {"number": number, "title": title, "state": state}


def issue(
    number,
    title,
    body="",
    labels=(),
    comments=(),
    state="OPEN",
    sub_issues=(),
    parent=None,
    blocked_by=(),
    url=None,
):
    return {
        "number": number,
        "title": title,
        "body": body,
        "state": state,
        "labels": [label(name) for name in labels],
        "comments": list(comments),
        "parent": nodes(parent or []),
        "subIssues": nodes(sub_issues),
        "blockedBy": nodes(blocked_by),
        "url": url or "https://github.com/test/repo/issues/%d" % number,
    }


def approved_feature(**overrides):
    fields = dict(
        number=1,
        title="Reduce bespoke tooling",
        body=DESIGN,
        labels=("type:feature", "repo:nix-config", "status:todo", "status:approved"),
        comments=(comment("sam", "Approved design sha256:%s" % DESIGN_SHA),),
        sub_issues=(sub(10, "T1: Build"), sub(11, "T2: Wire")),
    )
    fields.update(overrides)
    return issue(**fields)


class DesignHashTest(unittest.TestCase):
    def test_pinned_canonical_hash(self):
        self.assertEqual(sdlc_issues.design_hash(DESIGN), DESIGN_SHA)

    def test_ignores_crlf_trailing_space_and_blank_edges(self):
        noisy = DESIGN.replace("\n", "\r\n").replace(
            "1. One issue per feature.", "1. One issue per feature.   "
        )
        noisy = noisy.replace("## Plan", "\n\n## Plan") + "\r\n\r\n"
        self.assertEqual(sdlc_issues.design_hash(noisy), DESIGN_SHA)

    def test_drops_sam_annotation_lines(self):
        annotated = DESIGN.replace(
            "Use GitHub issues.", "> Sam: Is a label enough?\nUse GitHub issues."
        )
        self.assertEqual(sdlc_issues.design_hash(annotated), DESIGN_SHA)

    def test_stops_at_next_h2(self):
        changed_plan = DESIGN.replace("- [ ] T1: Build", "- [ ] T1: Different")
        self.assertEqual(sdlc_issues.design_hash(changed_plan), DESIGN_SHA)

    def test_missing_design_section(self):
        self.assertIsNone(sdlc_issues.design_hash("## Plan\n\n- [ ] T1: Build\n"))


class GhTest(unittest.TestCase):
    """Fake gh on PATH plus a temp registry; SDLC_REPO is test/repo."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = self.tmp.name
        self.state = os.path.join(self.root, "state")
        self.bin = os.path.join(self.root, "bin")
        os.makedirs(self.state)
        os.makedirs(self.bin)
        self.script("gh", FAKE_GH.replace("{python}", sys.executable))

    def script(self, name, source):
        path = os.path.join(self.bin, name)
        with open(path, "w") as fh:
            fh.write(source)
        os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR | stat.S_IXGRP)
        return path

    def serve(self, name, payload):
        with open(os.path.join(self.state, name), "w") as fh:
            fh.write(payload if isinstance(payload, str) else json.dumps(payload))

    def serve_list(self, issues):
        self.serve("list.json", issues)

    def serve_issue(self, iss):
        self.serve("issue-%d.json" % iss["number"], iss)

    def fakes(self):
        self.script("tuicr", FAKE_TUICR.replace("{python}", sys.executable))
        self.script("tv", FAKE_TV.replace("{python}", sys.executable))
        self.serve("tv-feature.txt", "1\n")

    def reset_calls(self):
        path = os.path.join(self.state, "calls.jsonl")
        if os.path.exists(path):
            os.unlink(path)

    def calls(self):
        path = os.path.join(self.state, "calls.jsonl")
        if not os.path.exists(path):
            return []
        with open(path) as fh:
            return [json.loads(line) for line in fh if line.strip()]

    def calls_for(self, *prefix):
        return [call for call in self.calls() if call[: len(prefix)] == list(prefix)]

    def tuicr_calls(self):
        path = os.path.join(self.state, "tuicr.jsonl")
        if not os.path.exists(path):
            return []
        with open(path) as fh:
            return [json.loads(line) for line in fh if line.strip()]

    def tv_calls(self):
        path = os.path.join(self.state, "tv.jsonl")
        if not os.path.exists(path):
            return []
        with open(path) as fh:
            return [json.loads(line) for line in fh if line.strip()]

    def run_cli(self, *args, stdin=None, path=None):
        env = dict(os.environ)
        env["PATH"] = self.bin + os.pathsep + (path if path is not None else env.get("PATH", ""))
        env["SDLC_REPO"] = "test/repo"
        env["FAKE_GH_STATE"] = self.state
        return subprocess.run(
            [sys.executable, CLI, *args],
            capture_output=True,
            text=True,
            env=env,
            input=stdin,
            stdin=subprocess.DEVNULL if stdin is None else None,
        )


class ListTest(GhTest):
    def setUp(self):
        super().setUp()
        self.active = issue(
            1,
            "Reduce bespoke tooling",
            DESIGN,
            ["type:feature", "repo:nix-config", "status:todo"],
        )
        self.done = issue(
            2,
            "Old done thing",
            DESIGN,
            ["type:feature", "repo:sdlc", "status:done"],
            state="CLOSED",
        )
        self.canceled = issue(
            3,
            "Canceled thing",
            DESIGN,
            ["type:feature", "repo:other", "status:canceled"],
        )
        self.task = issue(4, "Task not a feature", "", ["status:todo"])
        self.serve_list([self.active, self.done, self.canceled, self.task])

    def test_default_excludes_terminal_and_non_features(self):
        out = self.run_cli("list")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("#1", out.stdout)
        self.assertIn("Reduce bespoke tooling", out.stdout)
        self.assertIn("nix-config", out.stdout)
        self.assertIn("todo", out.stdout)
        for missing in ("#2", "#3", "#4"):
            self.assertNotIn(missing, out.stdout)

    def test_all_includes_closed_and_terminal(self):
        out = self.run_cli("list", "--all")
        self.assertEqual(out.returncode, 0, out.stderr)
        for present in ("#1", "#2", "#3"):
            self.assertIn(present, out.stdout)
        self.assertNotIn("#4", out.stdout)

    def test_path_format_is_tab_separated(self):
        out = self.run_cli("list", "--all", "--format", "path")
        self.assertEqual(out.returncode, 0, out.stderr)
        rows = [line.split("\t") for line in out.stdout.strip().splitlines()]
        self.assertEqual(len(rows), 3)
        self.assertEqual(rows[0], ["1", "Reduce bespoke tooling", "todo", "nix-config"])
        self.assertEqual(rows[1][:3], ["2", "Old done thing", "done"])
        self.assertEqual(rows[1][3], "sdlc")
        self.assertEqual(rows[2][2], "canceled")

    def test_json_format_is_an_array(self):
        out = self.run_cli("list", "--format", "json")
        self.assertEqual(out.returncode, 0, out.stderr)
        rows = json.loads(out.stdout)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["number"], 1)
        self.assertEqual(rows[0]["title"], "Reduce bespoke tooling")
        self.assertEqual(rows[0]["status"], "todo")
        self.assertEqual(rows[0]["repo"], "nix-config")

    def test_every_gh_call_names_the_registry_repo(self):
        self.run_cli("list")
        for call in self.calls():
            self.assertIn("--repo", call)
            self.assertEqual(call[call.index("--repo") + 1], "test/repo")

    def test_pick_prefers_fzf_and_prints_the_number(self):
        self.script(
            "fzf",
            "#!%s\nimport sys\nprint(sys.stdin.read().splitlines()[1])\n" % sys.executable,
        )
        out = self.run_cli("list", "--all", "--pick", path="")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stdout.strip(), "2")

    def test_pick_falls_back_to_a_numbered_prompt(self):
        out = self.run_cli("list", "--all", "--pick", stdin="3\n", path="")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stdout.strip(), "3")


class ShowTest(GhTest):
    def setUp(self):
        super().setUp()
        self.feature = issue(
            1,
            "Reduce bespoke tooling",
            DESIGN,
            ["type:feature", "repo:nix-config", "status:todo"],
            [comment("sam", "Please clarify the rollout.")],
        )
        self.serve_list([self.feature])
        self.serve_issue(self.feature)

    def test_show_prints_body_and_comment_thread(self):
        out = self.run_cli("show", "1")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("Use GitHub issues.", out.stdout)
        self.assertIn("Please clarify the rollout.", out.stdout)
        self.assertIn("sam", out.stdout)

    def test_show_resolves_a_title_substring(self):
        out = self.run_cli("show", "bespoke")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("Use GitHub issues.", out.stdout)


class StatusTest(GhTest):
    def serve_task_fixtures(self):
        self.serve_issue(issue(10, "T1: Build", labels=["status:todo"]))
        self.serve_issue(issue(11, "T2: Wire", labels=["status:todo"]))

    def test_approved_reports_hashes_author_and_counts(self):
        feature = approved_feature()
        self.serve_list([feature])
        self.serve_issue(feature)
        self.serve_issue(issue(10, "T1: Build", labels=["status:todo"]))
        self.serve_issue(
            issue(
                11,
                "T2: Wire",
                labels=["status:todo"],
                blocked_by=[sub(12, "T1 scaffold")],
            )
        )
        out = self.run_cli("status", "1")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("design_sha256=%s" % DESIGN_SHA, out.stdout)
        self.assertIn("approved_sha256=%s" % DESIGN_SHA, out.stdout)
        self.assertIn("approved_by=sam", out.stdout)
        self.assertIn("approved_at=%s" % COMMENT_AT, out.stdout)
        self.assertIn("approval=approved", out.stdout)
        self.assertIn("open=2", out.stdout)
        self.assertIn("ready=1", out.stdout)
        self.assertIn("blocked=1", out.stdout)

    def test_stale_when_design_changed_after_approval(self):
        old = DESIGN.replace("Use GitHub issues.", "Use a different tracker.")
        feature = approved_feature(
            comments=(comment("sam", "Approved design sha256:%s" % sdlc_issues.design_hash(old)),),
        )
        self.serve_list([feature])
        self.serve_issue(feature)
        self.serve_task_fixtures()
        out = self.run_cli("status", "1")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("approval=stale", out.stdout)
        self.assertIn("re-approval", out.stdout)

    def test_needs_reapproval_label_beats_approval(self):
        feature = approved_feature(
            labels=(
                "type:feature",
                "repo:nix-config",
                "status:todo",
                "status:approved",
                "status:needs-reapproval",
            )
        )
        self.serve_list([feature])
        self.serve_issue(feature)
        self.serve_task_fixtures()
        out = self.run_cli("status", "1")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("approval=stale", out.stdout)

    def test_missing_without_approval(self):
        feature = approved_feature(labels=("type:feature", "repo:nix-config", "status:todo"))
        self.serve_list([feature])
        self.serve_issue(feature)
        self.serve_task_fixtures()
        out = self.run_cli("status", "1")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("approval=missing", out.stdout)

    def test_status_uses_one_graphql_fetch(self):
        feature = approved_feature()
        self.serve_list([feature])
        self.serve_issue(feature)
        self.serve_task_fixtures()
        out = self.run_cli("status", "1")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(len(self.calls_for("api", "graphql")), 1)
        self.assertEqual(self.calls_for("issue", "view"), [])

    def test_quoted_approval_line_is_not_an_approval(self):
        feature = approved_feature(
            labels=("type:feature", "repo:nix-config", "status:todo"),
            comments=(comment("sam", "> Approved design sha256:%s" % DESIGN_SHA),),
        )
        self.serve_list([feature])
        self.serve_issue(feature)
        self.serve_task_fixtures()
        out = self.run_cli("status", "1")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("approval=missing", out.stdout)


class NextTest(GhTest):
    def ready_fixture(self, **feature_overrides):
        feature = approved_feature(**feature_overrides)
        self.serve_list([feature])
        self.serve_issue(feature)
        self.serve_issue(issue(10, "T1: Build", labels=["status:todo"]))
        self.serve_issue(issue(11, "T2: Wire", labels=["status:todo"]))
        return feature

    def test_next_uses_one_graphql_fetch(self):
        self.ready_fixture()
        out = self.run_cli("next", "1")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(len(self.calls_for("api", "graphql")), 1)
        self.assertEqual(self.calls_for("issue", "view"), [])

    def test_next_prints_the_ready_task(self):
        self.ready_fixture()
        out = self.run_cli("next", "1")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("#10", out.stdout)
        self.assertIn("T1: Build", out.stdout)

    def test_next_without_feature_uses_first_active(self):
        self.ready_fixture()
        out = self.run_cli("next")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("#10", out.stdout)

    def test_next_refuses_with_the_blocker(self):
        self.ready_fixture()
        self.serve_issue(
            issue(10, "T1: Build", labels=["status:todo"], blocked_by=[sub(7, "T0: Setup")])
        )
        self.serve_issue(issue(11, "T2: Wire", labels=["status:done"], state="CLOSED"))
        out = self.run_cli("next", "1")
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("#7", out.stderr)
        self.assertIn("blocked by", out.stderr)

    def test_next_refuses_when_design_is_stale(self):
        old = DESIGN.replace("Use GitHub issues.", "Use a different tracker.")
        self.ready_fixture(
            comments=(comment("sam", "Approved design sha256:%s" % sdlc_issues.design_hash(old)),),
        )
        out = self.run_cli("next", "1")
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("re-approval", out.stderr)

    def test_next_refuses_when_approval_is_missing(self):
        self.ready_fixture(labels=("type:feature", "repo:nix-config", "status:todo"))
        out = self.run_cli("next", "1")
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("not approved", out.stderr)
        self.assertIn("approve", out.stderr)


class ApproveTest(GhTest):
    def setUp(self):
        super().setUp()
        self.feature = issue(
            1,
            "Reduce bespoke tooling",
            DESIGN,
            ["type:feature", "repo:nix-config", "status:todo"],
        )
        self.serve_list([self.feature])
        self.serve_issue(self.feature)

    def test_requires_a_tty_without_yes(self):
        out = self.run_cli("approve", "1")
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("TTY", out.stderr + out.stdout)
        self.assertEqual(self.calls(), [])

    def test_adds_label_and_posts_hash_comment(self):
        out = self.run_cli("approve", "1", "--yes")
        self.assertEqual(out.returncode, 0, out.stderr)
        edits = self.calls_for("issue", "edit")
        self.assertEqual(len(edits), 1)
        edit = edits[0]
        self.assertEqual(edit[edit.index("--add-label") + 1], "status:approved")
        self.assertNotIn("status:todo", edit)
        comments = self.calls_for("issue", "comment")
        self.assertEqual(len(comments), 1)
        self.assertEqual(
            comments[0][comments[0].index("--body") + 1],
            "Approved design sha256:%s" % DESIGN_SHA,
        )
        self.assertIn("sha256:%s" % DESIGN_SHA, out.stdout)

    def test_refuses_non_feature(self):
        task = issue(10, "Task", DESIGN, ["status:todo"])
        self.serve_list([self.feature, task])
        self.serve_issue(task)
        out = self.run_cli("approve", "10", "--yes")
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("type:feature", out.stderr + out.stdout)

    def test_removes_needs_reapproval_when_present(self):
        self.feature["labels"].append(label("status:needs-reapproval"))
        self.serve_issue(self.feature)
        out = self.run_cli("approve", "1", "--yes")
        self.assertEqual(out.returncode, 0, out.stderr)
        edit = self.calls_for("issue", "edit")[0]
        self.assertEqual(edit[edit.index("--remove-label") + 1], "status:needs-reapproval")


class NewTest(GhTest):
    def test_parses_printed_url_and_labels_the_code_repo(self):
        self.serve("create_url.txt", "https://github.com/test/repo/issues/7\n")
        out = self.run_cli("new", "my-feature", "--repo", "acme/widget")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("#7", out.stdout)
        self.assertIn("https://github.com/test/repo/issues/7", out.stdout)
        create = self.calls_for("issue", "create")[0]
        self.assertEqual(create[create.index("--repo") + 1], "test/repo")
        for expected in ("type:feature", "repo:widget", "status:todo"):
            self.assertIn(expected, create)
        body = create[create.index("--body") + 1]
        self.assertIn("## Design", body)
        self.assertIn("## Plan", body)
        self.assertEqual(create[create.index("--title") + 1], "my feature")

    def test_title_override(self):
        self.serve("create_url.txt", "https://github.com/test/repo/issues/8\n")
        out = self.run_cli("new", "my-feature", "--repo", "acme/widget", "--title", "My Thing")
        self.assertEqual(out.returncode, 0, out.stderr)
        create = self.calls_for("issue", "create")[0]
        self.assertEqual(create[create.index("--title") + 1], "My Thing")


class TaskTest(GhTest):
    def setUp(self):
        super().setUp()
        body = DESIGN + "\n- [ ] T2: Wire (#12)\n"
        self.feature = issue(
            1,
            "Reduce bespoke tooling",
            body,
            ["type:feature", "repo:nix-config", "status:todo", "status:approved"],
            [comment("sam", "Approved design sha256:%s" % sdlc_issues.design_hash(body))],
            sub_issues=(sub(10, "T1: Build"), sub(12, "T2: Wire")),
        )
        self.serve_list([self.feature])
        self.serve_issue(self.feature)
        self.serve("create_url.txt", "https://github.com/test/repo/issues/13\n")

    def test_task_add_sets_parent_and_translates_labels(self):
        out = self.run_cli("task", "add", "1", "T3: Test", "--needs", "T1,T2")
        self.assertEqual(out.returncode, 0, out.stderr)
        create = self.calls_for("issue", "create")[0]
        self.assertEqual(create[create.index("--parent") + 1], "1")
        blocked = [create[i + 1] for i, arg in enumerate(create) if arg == "--blocked-by"]
        self.assertEqual(blocked, ["10,12"])
        self.assertIn("status:todo", create)
        self.assertEqual(create[create.index("--title") + 1], "T3: Test")
        self.assertIn("#13", out.stdout)

    def test_task_add_accepts_issue_numbers(self):
        out = self.run_cli("task", "add", "1", "T4: More", "--needs", "10,#12")
        self.assertEqual(out.returncode, 0, out.stderr)
        create = self.calls_for("issue", "create")[0]
        blocked = [create[i + 1] for i, arg in enumerate(create) if arg == "--blocked-by"]
        self.assertEqual(blocked, ["10,12"])

    def test_task_add_rejects_unknown_label(self):
        out = self.run_cli("task", "add", "1", "T9: Nope", "--needs", "T8")
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("T8", out.stderr)
        self.assertEqual(self.calls_for("issue", "create"), [])

    def test_task_start_swaps_the_lifecycle_label(self):
        self.serve_issue(issue(10, "T1: Build", labels=["status:todo"]))
        out = self.run_cli("task", "start", "10")
        self.assertEqual(out.returncode, 0, out.stderr)
        edit = self.calls_for("issue", "edit")[0]
        self.assertEqual(edit[edit.index("--add-label") + 1], "status:in-progress")
        self.assertIn("status:todo", edit)
        self.assertEqual(self.calls_for("issue", "close"), [])

    def test_task_done_closes_the_issue(self):
        self.serve_issue(issue(10, "T1: Build", labels=["status:in-progress"]))
        out = self.run_cli("task", "done", "10")
        self.assertEqual(out.returncode, 0, out.stderr)
        edit = self.calls_for("issue", "edit")[0]
        self.assertEqual(edit[edit.index("--add-label") + 1], "status:done")
        self.assertIn("status:in-progress", edit)
        self.assertEqual(len(self.calls_for("issue", "close")), 1)

    def test_task_cancel_closes_the_issue(self):
        self.serve_issue(issue(10, "T1: Build", labels=["status:todo"]))
        out = self.run_cli("task", "cancel", "10")
        self.assertEqual(out.returncode, 0, out.stderr)
        edit = self.calls_for("issue", "edit")[0]
        self.assertEqual(edit[edit.index("--add-label") + 1], "status:canceled")
        self.assertEqual(len(self.calls_for("issue", "close")), 1)


class FeatureTerminalTest(GhTest):
    def setUp(self):
        super().setUp()
        self.feature = issue(
            1,
            "Reduce bespoke tooling",
            DESIGN,
            ["type:feature", "repo:nix-config", "status:todo"],
        )
        self.serve_list([self.feature])
        self.serve_issue(self.feature)

    def test_complete_sets_done_and_closes(self):
        out = self.run_cli("complete", "1")
        self.assertEqual(out.returncode, 0, out.stderr)
        edit = self.calls_for("issue", "edit")[0]
        self.assertEqual(edit[edit.index("--add-label") + 1], "status:done")
        self.assertEqual(len(self.calls_for("issue", "close")), 1)

    def test_complete_refuses_open_tasks(self):
        feature = issue(
            1,
            "Reduce bespoke tooling",
            DESIGN,
            ["type:feature", "repo:nix-config", "status:todo"],
            sub_issues=(sub(10, "T1: Build"),),
        )
        self.serve_list([feature])
        self.serve_issue(feature)
        self.serve_issue(issue(10, "T1: Build", labels=["status:todo"]))
        out = self.run_cli("complete", "1")
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("open task", out.stderr + out.stdout)
        self.assertEqual(self.calls_for("issue", "close"), [])

    def test_cancel_sets_canceled_and_closes(self):
        out = self.run_cli("cancel", "1")
        self.assertEqual(out.returncode, 0, out.stderr)
        edit = self.calls_for("issue", "edit")[0]
        self.assertEqual(edit[edit.index("--add-label") + 1], "status:canceled")
        self.assertEqual(len(self.calls_for("issue", "close")), 1)


class TuicrExportTest(unittest.TestCase):
    def test_parses_file_line_and_range_anchors(self):
        notes = sdlc_issues.parse_tuicr_export(EXPORT)
        self.assertEqual([n.anchor for n in notes], ["body.md:7", "body.md:13-15"])
        self.assertEqual(notes[0].file, "body.md")
        self.assertEqual((notes[0].start, notes[0].end), (7, None))
        self.assertEqual((notes[1].start, notes[1].end), (13, 15))
        self.assertEqual(notes[0].text, "Make this a link.")

    def test_keeps_continuation_lines(self):
        text = "1. `a.md:3` - first\n  second line\n\n2. `a.md` - file note\n"
        notes = sdlc_issues.parse_tuicr_export(text)
        self.assertEqual(notes[0].text, "first\nsecond line")
        self.assertEqual((notes[1].start, notes[1].end), (None, None))

    def test_ignores_the_preamble(self):
        self.assertEqual(sdlc_issues.parse_tuicr_export("nothing here\n"), [])

    def test_parses_typed_and_commit_scoped_items(self):
        notes = sdlc_issues.parse_tuicr_export(TYPED_EXPORT)
        self.assertEqual([note.start for note in notes], [7, 13])
        self.assertEqual(notes[0].text, "Typed note.")
        self.assertEqual(notes[1].text, "Range note.")

    def test_preserves_blank_lines_inside_a_note(self):
        text = "1. `a.md:3` - first\n   \n   second paragraph\n"
        notes = sdlc_issues.parse_tuicr_export(text)
        self.assertEqual(notes[0].text, "first\n\nsecond paragraph")


class ReviewRenderTest(unittest.TestCase):
    def note(self, anchor="body.md:7", start=7, end=None, text="Make this a link."):
        return sdlc_issues.ReviewNote(anchor, "body.md", start, end, text)

    def test_quotes_the_anchored_body_lines(self):
        text = sdlc_issues.render_review(1, "Title", DESIGN, [self.note()])
        self.assertIn("## Review — #1 Title", text)
        self.assertIn("design sha256:%s" % DESIGN_SHA[:12], text)
        self.assertIn("### line 7", text)
        self.assertIn("> Use GitHub issues.", text)
        self.assertIn("<!-- sdlc-review:n1:", text)

    def test_quotes_ranges(self):
        text = sdlc_issues.render_review(
            1, "Title", DESIGN, [self.note("body.md:13-15", 13, 15, "Split it.")]
        )
        self.assertIn("> ## Plan", text)
        self.assertIn("> - [ ] T1: Build", text)

    def test_skips_markers_already_posted(self):
        note = self.note()
        marker = sdlc_issues.review_marker(1, note, DESIGN.split("\n"))
        self.assertEqual(sdlc_issues.render_review(1, "Title", DESIGN, [note], {marker}), "")

    def test_marker_is_stable_for_the_same_anchor_and_text(self):
        self.assertEqual(
            sdlc_issues.review_marker(1, self.note()),
            sdlc_issues.review_marker(1, self.note()),
        )

    def test_marker_ignores_line_shift_but_tracks_content(self):
        body = "x\ny\nsame\nsame\n"
        lines = body.split("\n")
        first = sdlc_issues.ReviewNote("f:3", "f", 3, None, "note")
        shifted = sdlc_issues.ReviewNote("f:4", "f", 4, None, "note")
        self.assertEqual(
            sdlc_issues.review_marker(1, first, lines),
            sdlc_issues.review_marker(1, shifted, lines),
        )
        changed = "x\ny\nchanged\nsame\n"
        self.assertNotEqual(
            sdlc_issues.review_marker(1, first, lines),
            sdlc_issues.review_marker(1, first, changed.split("\n")),
        )


class ReviewCliTest(GhTest):
    def setUp(self):
        super().setUp()
        self.serve_issue(approved_feature())
        self.fakes()

    def export(self, text=EXPORT):
        self.serve("tuicr-export.md", text)

    def posted(self):
        with open(os.path.join(self.state, "last-comment.md")) as fh:
            return fh.read()

    def test_hands_the_body_to_tuicr_in_stdout_mode(self):
        self.export()
        self.run_cli("review", "1")
        args = self.tuicr_calls()[0]
        self.assertIn("--stdout", args)
        self.assertIn("--file", args)
        with open(os.path.join(self.state, "reviewed-body.md")) as fh:
            self.assertEqual(fh.read(), DESIGN)

    def test_posts_one_aggregated_comment_with_quotes(self):
        self.export()
        out = self.run_cli("review", "1")
        self.assertEqual(out.returncode, 0, out.stderr)
        body = self.posted()
        self.assertIn("## Review — #1", body)
        self.assertIn("> Use GitHub issues.", body)
        self.assertIn("> ## Plan", body)
        self.assertIn("design sha256:%s" % DESIGN_SHA[:12], body)
        self.assertEqual(len(self.calls_for("issue", "comment")), 1)
        self.assertIn("tell the agent", out.stdout)

    def test_dry_run_prints_without_posting(self):
        self.export()
        out = self.run_cli("review", "1", "--dry-run")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("> Use GitHub issues.", out.stdout)
        self.assertEqual(self.calls_for("issue", "comment"), [])

    def test_no_comments_does_not_post(self):
        out = self.run_cli("review", "1")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("no review notes", out.stdout)
        self.assertEqual(self.calls_for("issue", "comment"), [])

    def test_second_run_skips_markers_already_posted(self):
        self.export()
        self.run_cli("review", "1")
        posted = self.posted()
        self.serve_issue(approved_feature(comments=(comment("sam", posted),)))
        self.reset_calls()
        out = self.run_cli("review", "1")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("no new review notes", out.stdout)
        self.assertEqual(self.calls_for("issue", "comment"), [])


class UiCliTest(GhTest):
    def setUp(self):
        super().setUp()
        feature = issue(
            1,
            "Reduce bespoke tooling",
            DESIGN,
            ["type:feature", "repo:nix-config", "status:todo"],
        )
        self.serve_issue(feature)
        self.serve_list([feature])
        self.fakes()

    def test_picks_the_feature_before_the_action(self):
        self.run_cli("ui")
        calls = self.tv_calls()
        self.assertGreaterEqual(len(calls), 2)
        self.assertTrue(any("sdlc-features" in call for call in calls[:1]))
        self.assertFalse(any("sdlc-features" in call for call in calls[1:2]))

    def test_approve_stays_behind_the_tty_gate(self):
        out = self.run_cli("ui", "1", "approve")
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("TTY", out.stderr + out.stdout)
        self.assertEqual(self.calls_for("issue", "edit"), [])

    def test_action_and_feature_dispatch_without_tv(self):
        out = self.run_cli("ui", "show", "1")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("Use GitHub issues.", out.stdout)
        self.assertEqual(self.tv_calls(), [])

    def test_feature_arg_opens_the_action_picker(self):
        out = self.run_cli("ui", "1")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("Use GitHub issues.", out.stdout)
        self.assertTrue(self.tv_calls())

    def test_action_arg_opens_the_feature_picker(self):
        out = self.run_cli("ui", "show")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("Use GitHub issues.", out.stdout)
        self.assertTrue(any("sdlc-features" in call for call in self.tv_calls()))

    def test_complete_declines_by_default(self):
        out = self.run_cli("ui", "1", "complete", stdin="n\n")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(self.calls_for("issue", "close"), [])

    def test_complete_runs_after_yes(self):
        out = self.run_cli("ui", "1", "complete", stdin="y\n")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(len(self.calls_for("issue", "close")), 1)

    def test_cancel_runs_after_yes(self):
        out = self.run_cli("ui", "1", "cancel", stdin="y\n")
        self.assertEqual(out.returncode, 0, out.stderr)
        edit = self.calls_for("issue", "edit")[0]
        self.assertEqual(edit[edit.index("--add-label") + 1], "status:canceled")

    def test_rejects_two_feature_tokens(self):
        out = self.run_cli("ui", "1", "2")
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("one feature", out.stderr)


class CommentCliTest(GhTest):
    def setUp(self):
        super().setUp()
        feature = issue(
            1,
            "Reduce bespoke tooling",
            DESIGN,
            ["type:feature", "repo:nix-config", "status:todo"],
        )
        self.serve_issue(feature)
        self.serve_list([feature])
        self.fakes()

    def test_comment_opens_the_editor(self):
        out = self.run_cli("comment", "1")
        self.assertEqual(out.returncode, 0, out.stderr)
        call = self.calls_for("issue", "comment")[0]
        self.assertIn("--editor", call)

    def test_comment_without_a_feature_uses_the_picker(self):
        out = self.run_cli("comment")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertTrue(any("sdlc-features" in call for call in self.tv_calls()))


class PickerCableTest(unittest.TestCase):
    def test_preview_reads_precomputed_files_instead_of_github(self):
        features = [
            issue(1, "One", DESIGN, ["type:feature", "repo:nix-config", "status:todo"]),
            issue(
                2,
                "Two",
                "## Design\n\nSecond.\n",
                ["type:feature", "repo:sdlc", "status:todo"],
            ),
        ]
        with tempfile.TemporaryDirectory() as tmp:
            cable = sdlc_issues.write_picker_cable(tmp, features)
            with open(os.path.join(cable, "sdlc-features.toml")) as fh:
                channel = fh.read()
            self.assertIn("cat ", channel)
            self.assertNotIn("status {split", channel)
            with open(os.path.join(tmp, "previews", "1.md")) as fh:
                preview = fh.read()
            self.assertIn("#1 One", preview)
            self.assertIn("Use GitHub issues.", preview)


class RepoNameTest(unittest.TestCase):
    def test_uses_the_origin_remote(self):
        with tempfile.TemporaryDirectory() as tmp:
            subprocess.run(["git", "init", "-q", tmp], check=True)
            subprocess.run(
                ["git", "-C", tmp, "remote", "add", "origin", "git@github.com:acme/widget.git"],
                check=True,
            )
            self.assertEqual(sdlc_issues.cwd_repo_name(tmp), "widget")


class CleanTest(unittest.TestCase):
    def test_clean_strips_control_characters_and_keeps_whitespace(self):
        self.assertEqual(sdlc_issues.clean("a\x1b[31mb\nc\t"), "a[31mb\nc\t")

    def test_one_line_removes_layout_characters(self):
        self.assertEqual(sdlc_issues.one_line("a\tb\nc\r"), "a b c ")

    def test_path_row_cleans_the_title(self):
        row = sdlc_issues.path_row(issue(1, "bad\x1b[31mtitle", labels=["repo:nix-config"]))
        self.assertNotIn("\x1b", row)


if __name__ == "__main__":
    unittest.main()
