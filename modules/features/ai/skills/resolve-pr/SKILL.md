---
name: resolve-pr
description: Resolve a GitHub PR by handling merge conflicts, unresolved review threads, and actionable CI failures until ready.
argument-hint: [pr-number]
---

# Resolve PR

Priority: merge conflicts → review threads → CI. Use the watcher; it runs `gh pr checks --watch --fail-fast` and checks comments every 20 seconds while CI is pending.

## Setup

```bash
WATCH_PR="$HOME/code/github.com/smores56/nix-config/modules/features/ai/skills/resolve-pr/scripts/watch-pr.sh"
PR_ARG="${1:-}"
PR=$(gh pr view ${PR_ARG:+"$PR_ARG"} --json number -q .number 2>/dev/null) || {
  echo "No PR found for current branch. Provide a PR number."
  exit 1
}
BASE=$(gh pr view "$PR" --json baseRefName -q .baseRefName)
ITERATION=0
```

## Loop

Run the watcher and handle the JSON event on its last stdout line. The watcher exits immediately for merge conflicts or unresolved comments; otherwise it waits on CI while checking comments every 20 seconds.

```bash
COMMENT_INTERVAL=20 bash "$WATCH_PR" "$PR"
```

Events:

- `merge_conflict`: merge `origin/$BASE`, resolve conflicts, test touched areas, commit, push, restart loop.
- `new_comments`: handle every thread in `threads`; push once if code changed, restart loop.
- `ci_ready` + `conclusion=failure`: fetch failed logs, fix actionable failures, test, push, restart loop.
- `ci_ready` + `conclusion=success`: run final verification.
- `ci_ready` + `conclusion=pending|no_checks`: report state; rerun watcher only if continued monitoring is desired.

After any push, increment `ITERATION`; stop after 10 iterations and report remaining blockers.

## Merge conflicts

```bash
git status --short
git fetch origin "$BASE"
git merge --no-edit "origin/$BASE"
git diff --name-only --diff-filter=U
```

Resolve conflicts, then verify and push:

```bash
git diff --check
test -z "$(git diff --name-only --diff-filter=U)"
git add <resolved-files>
git commit -m "fix: resolve merge conflicts"
git push
```

Ask before touching unrelated user changes. Preserve PR intent unless base clearly supersedes it.

## Review threads

For each unresolved thread:

1. Read the referenced file around `path:line`.
2. Classify the thread:
   - `VALID`: fix it.
   - `INVALID`: already fixed, false positive, removed code, or intentional design.
   - `BLOCKED`: needs user/reviewer judgment.
3. Reply with `[agent] ...`.
4. Resolve valid/invalid threads; leave blocked threads open.
5. Push once if code changed.

Use GraphQL variables so reply bodies do not break shell quoting:

```bash
gh api graphql \
  -F thread="THREAD_ID" \
  -f body='[agent] BODY' \
  -f query='mutation($thread: ID!, $body: String!) { addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $thread, body: $body}) { comment { url } } }'

gh api graphql \
  -F thread="THREAD_ID" \
  -f query='mutation($thread: ID!) { resolveReviewThread(input: {threadId: $thread}) { thread { isResolved } } }'
```

## CI failures

For each failed check in `failures`:

```bash
RUN_ID=$(echo "$link" | sed -n 's|.*/runs/\([0-9]*\).*|\1|p')
test -n "$RUN_ID" && gh run view "$RUN_ID" --log-failed 2>&1 | tail -200
```

- infra/flaky: report; do not retry blindly.
- human gate: report; do not wait forever.
- lint/type/test/format/generated-code: fix root cause, verify locally, push once.

## Final verification

```bash
gh pr view "$PR" --json mergeStateStatus -q .mergeStateStatus
COMMENT_INTERVAL=20 bash "$WATCH_PR" "$PR"
```

Done only when merge state is not `DIRTY`, the watcher reports no unresolved threads, and CI has no `fail` or `pending` buckets.
