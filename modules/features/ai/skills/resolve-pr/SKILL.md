---
name: resolve-pr
description: Resolve a GitHub PR — merge conflicts, unresolved review threads, actionable CI failures — until it is ready to merge.
argument-hint: [pr-number]
---

# Resolve PR

Priority: merge conflicts → review threads → CI.

Use the helper for GitHub API work, replies, thread resolution, CI log extraction, and final verification:

```bash
WATCH_PR="$HOME/code/github.com/smores56/nix-config/modules/features/ai/skills/resolve-pr/scripts/watch-pr.sh"
PR="${1:-}"
ITERATION=0
```

## Loop

Run:

```bash
COMMENT_INTERVAL=20 bash "$WATCH_PR" watch $PR
```

Handle the JSON event from the last stdout line:

- `merge_conflict`: merge `origin/<base>`, resolve conflicts, test, commit, push, restart.
- `new_comments`: handle every thread in `threads`; push once if code changed, restart.
- `ci_ready` + `conclusion=failure`: fetch logs, fix actionable failures, test, push, restart.
- `ci_ready` + `conclusion=success`: run `verify`.
- `ci_ready` + `conclusion=pending|no_checks`: report state; rerun watcher only if continued monitoring is desired.
- `ready`: done.

After any push, increment `ITERATION`; stop after 10 iterations and report blockers.

## Merge conflicts

Use `base` from the `merge_conflict` event:

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
2. Classify it:
   - `VALID`: fix it.
   - `INVALID`: already fixed, false positive, removed code, or intentional design.
   - `BLOCKED`: needs user/reviewer judgment.
3. Reply with `[agent] ...`.
4. Resolve valid/invalid threads; leave blocked threads open.
5. Push once if code changed.

```bash
bash "$WATCH_PR" reply THREAD_ID '[agent] BODY'
bash "$WATCH_PR" resolve THREAD_ID
```

## CI failures

For each failed check in `failures`, prefer `run_id`; otherwise pass `link`:

```bash
bash "$WATCH_PR" log "$RUN_ID_OR_LINK"
```

- infra/flaky: report; do not retry blindly.
- human gate: report; do not wait forever.
- lint/type/test/format/generated-code: fix root cause, verify locally, push once.

## Final verification

```bash
bash "$WATCH_PR" verify $PR
```

Done only when it emits `{"event":"ready"}`.
