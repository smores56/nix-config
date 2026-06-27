---
name: resolve-pr
description: Monitor CI checks, fix actionable failures, and resolve PR review comments until merge-ready. Works in any GitHub repo. Loops until CI is green and all review threads are resolved.
argument-hint: [pr-number]
---

# Resolve PR

Automates the CI-wait, fix, review-comment loop until a PR is merge-ready. Uses an exit-on-event watcher script: the agent is idle while waiting and wakes only on actionable events. Works in any GitHub repository.

Scripts (relative to this skill's directory):

- `scripts/ci-watch.sh` — polls CI check-runs and review comments via `gh api`; exits on first actionable event. Run as a background shell task when the harness supports it.
- `scripts/run-bash.sh` — pipe complex bash (GraphQL mutations, JSON bodies) through this to avoid shell-escaping issues.

## Progress Checklist

Copy and track as you go:

```
Resolve PR Progress:
- [ ] Setup — resolve PR number, owner, repo
- [ ] Handle events from watcher (loop until done):
  - [ ] merge_conflict → merge base, resolve conflicts, push
  - [ ] new_comments → resolve each thread (validate, fix or rebut)
  - [ ] ci_complete with failures → fix actionable failures via subagents
  - [ ] ci_complete with no failures → final comment check, then done
- [ ] Push changes and re-launch watcher (max 10 iterations)
- [ ] Final verification — mergeable, CI green, no unresolved threads
```

## 1. Setup

Resolve the scripts directory path first. Prefer the current tool's installed skill path; fall back to the common user skill locations:

```bash
SKILL_DIR="$(dirname "$(find -L ~/.claude/skills ~/.codex/skills ~/.config/maki/skills ~/.omp/agent/skills -path '*/resolve-pr/SKILL.md' -print -quit 2>/dev/null)")"
SCRIPTS="$SKILL_DIR/scripts"
test -n "$SKILL_DIR" && test -d "$SCRIPTS"
```

Then resolve PR metadata:

```bash
PR=$(gh pr view --json number -q '.number' 2>/dev/null || echo "$1")
PR_URL=$(gh pr view "$PR" --json url -q '.url')
OWNER=$(gh repo view --json owner -q '.owner.login')
NAME=$(gh repo view --json name -q '.name')
BASE=$(gh pr view "$PR" --json baseRefName -q '.baseRefName')
echo "PR=$PR PR_URL=$PR_URL OWNER=$OWNER NAME=$NAME BASE=$BASE"
```

If `gh pr view` fails (no PR for current branch), tell the user to create a PR first and **stop**.

Capture `PR`, `PR_URL`, `OWNER`, `NAME`, and `BASE`. Initialize state:

```
CI_INTERVAL=30
KNOWN_THREADS=""
ITERATION=0
```

Print `Resolving PR #<number> — <url>` to confirm.

## 2. Launch Watcher

Run as a background shell task when available, with a long timeout:

```bash
bash $SCRIPTS/ci-watch.sh $PR --interval $CI_INTERVAL --known-threads "$KNOWN_THREADS"
```

The agent is now idle — zero token consumption. It will be automatically notified when the script exits.

## 3. Handle Event

When the background task completes, read the output. The last stdout line is a JSON event:

- **`merge_conflict`** — PR cannot merge cleanly. Run **Step 4** (Merge Conflicts). After resolving, push and re-launch
  (Step 8).
- **`new_comments`** — extract `threads`, run **Step 6** (Review Comments). Update `KNOWN_THREADS` from the event's
  `known_threads` field. After handling, go to **Step 8** (Re-launch).
- **`ci_complete` with `"conclusion":"failure"`** — run **Step 5** (CI Failures). After fixing, push and re-launch (Step
  8).
- **`ci_complete` with `"conclusion":"success"`** — CI passed. Do a final one-shot comment check (Step 6) then go to
  **Step 7** (Verify).

## 4. Merge Conflicts

When GitHub reports merge conflicts, resolve them before CI or review comments. Do not wait for CI: conflicted PRs often
stop or hide useful checks.

1. Confirm the worktree is clean except for intentional agent changes:
   ```bash
   git status --short
   ```
   If unrelated user changes exist, ask before touching them.
2. Fetch and merge the PR base branch into the PR branch:
   ```bash
   git fetch origin "$BASE"
   git merge --no-edit "origin/$BASE"
   ```
3. If the merge exits with conflicts, list conflicted files:
   ```bash
   git diff --name-only --diff-filter=U
   git status --short
   ```
4. Resolve every conflict in the smallest safe way:
   - Preserve the PR's intended behavior unless the base branch clearly supersedes it.
   - Read both sides and nearby code before choosing.
   - Run focused tests, formatters, or type checks for touched areas.
   - If a conflict requires product/design judgment, stop and ask the user with the file path and conflicting choices.
5. Verify no unmerged entries remain:
   ```bash
   git diff --check
   test -z "$(git diff --name-only --diff-filter=U)"
   ```
6. Commit and push the merge resolution:
   ```bash
   git add <resolved-files>
   git commit -m "fix: resolve merge conflicts"
   git push
   ```

## 5. CI Failures

For each failed check in `failures`:

1. Extract run ID from `link`: `echo "$link" | sed -n 's|.*/runs/\([0-9]*\)/.*|\1|p'`
2. Fetch logs: `gh run view <run-id> --log-failed 2>&1 | tail -100`
3. Classify:
   - **Infra** (runner timeout, service down, rate limit, OOM, network error) — skip and report to user
   - **Flaky** (identical failure on retry with no code change between attempts) — skip and report to user
   - **Actionable** (lint, type error, test failure, format, stale generated code) — delegate a bounded implementation task if available. Provide: truncated failure logs, check name, changed file paths (`git diff --name-only origin/$BASE...HEAD`), and verification command.
4. After all fixes complete, `git push` once.

## 6. Review Comments

### Fetch threads

Use threads from the `new_comments` event (already filtered to new-only by the watcher). For a final one-shot check
after CI passes, fetch directly:

```bash
cat <<'BASH' | bash $SCRIPTS/run-bash.sh
gh api graphql \
  -F owner="$OWNER" -F repo="$NAME" -F pr="$PR" \
  -f query='query($owner: String!, $repo: String!, $pr: Int!) {
    repository(owner: $owner, name: $repo) {
      pullRequest(number: $pr) {
        reviewThreads(first: 100) {
          nodes {
            id isResolved isOutdated path line startLine diffSide
            comments(first: 10) {
              nodes { body author { login } url createdAt }
            }
          }
        }
      }
    }
  }' \
| jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)]'
BASH
```

If empty, skip to Step 7.

### Validate and act

For each unresolved thread:

1. Read the file at `path` around `line` (~20 lines context).
2. Classify as **VALID** (issue still exists in code) or **INVALID** (already fixed, code removed, false positive, or
   intentional design). **Do NOT trust `isOutdated`** — always read the code.
3. Reply and resolve using `run-bash.sh` (bodies may contain special characters):
   ```bash
   cat <<'BASH' | bash $SCRIPTS/run-bash.sh
   gh api graphql -f query='mutation { addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: "THREAD_ID", body: "BODY"}) { comment { url } } }'
   gh api graphql -f query='mutation { resolveReviewThread(input: {threadId: "THREAD_ID"}) { thread { isResolved } } }'
   BASH
   ```
   - **Invalid** — body: `[agent] <reason>`
   - **Valid** — fix directly or delegate a bounded implementation task if available. Provide: the comment body, file path + line range, ~20 lines surrounding context, and the PR diff for that file. After fix, reply: `[agent] Fixed in <sha> — <explanation>`.

After all threads processed, `git push` once if any fixes were made.

## 7. Final Verification

1. Check mergeability:
   ```bash
   gh pr view "$PR" --json mergeStateStatus -q '.mergeStateStatus'
   ```
   If it is `DIRTY`, run Step 4.
2. Fetch all unresolved threads (Step 6 one-shot fetch).
3. If any remain, handle them (Step 6) and push.
4. Report final status: merge state, CI state, remaining threads (if any), total iterations used.

## 8. Re-launch Cycle

After handling an event and pushing any changes:

1. Increment `ITERATION`.
2. If code was pushed, reset `KNOWN_THREADS=""` (new commits invalidate prior thread state).
3. If `ITERATION >= 10`, report remaining issues and **stop** (max 10 full cycles).
4. Otherwise, go back to **Step 2** with updated `KNOWN_THREADS`.

## Rules

- Prefix all GitHub comments with `[agent]`
- Merge conflicts: resolve before CI/review-comment work
- Infra/flaky failures: skip and report, never retry
- Delegation failures: skip the item and report, do not block
- Max 10 total iterations through the fix cycle
- Always push once at the end of a fix batch, not per-fix
- Use `scripts/run-bash.sh` for multi-line GraphQL or JSON-body commands
- If no PR exists for the current branch, tell the user and stop
