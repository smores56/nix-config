#!/usr/bin/env bash
set -euo pipefail

PR="${1:-}"
COMMENT_INTERVAL="${COMMENT_INTERVAL:-20}"
case "$COMMENT_INTERVAL" in
	'' | *[!0-9]*) echo "COMMENT_INTERVAL must be seconds" >&2; exit 2 ;;
esac
[[ -n "$PR" ]] || PR=$(gh pr view --json number -q .number)

OWNER=$(gh repo view --json owner -q .owner.login)
REPO=$(gh repo view --json name -q .name)
BASE=$(gh pr view "$PR" --json baseRefName -q .baseRefName)

query='query($owner: String!, $repo: String!, $pr: Int!, $endCursor: String) {
  repository(owner: $owner, name: $repo) { pullRequest(number: $pr) {
    reviewThreads(first: 100, after: $endCursor) {
      nodes { id isResolved isOutdated path line startLine diffSide comments(first: 20) { nodes { body author { login } url createdAt } } }
      pageInfo { hasNextPage endCursor }
    }
  } }
}'

threads() {
	gh api graphql --paginate -F owner="$OWNER" -F repo="$REPO" -F pr="$PR" -f query="$query" |
		jq -s -c '[.[].data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)]'
}

checks() {
	gh pr checks "$PR" --json name,state,bucket,link,workflow 2>/dev/null || echo '[]'
}

emit_conflict() {
	state=$(gh pr view "$PR" --json mergeStateStatus -q .mergeStateStatus 2>/dev/null || echo UNKNOWN)
	[[ "$state" != DIRTY ]] || { jq -nc --arg base "$BASE" '{event:"merge_conflict", base:$base}'; exit 0; }
}

emit_threads() {
	current=$(threads)
	[[ $(jq length <<<"$current") -eq 0 ]] || { jq -nc --argjson threads "$current" '{event:"new_comments", threads:$threads}'; exit 0; }
}

emit_ci() {
	current=$(checks)
	failures=$(jq -c '[.[] | select(.bucket == "fail" or (.state | IN("FAILURE", "ERROR", "CANCELLED"))) | {name, link}]' <<<"$current")
	pending=$(jq '[.[] | select(.bucket == "pending" or (.state | IN("PENDING", "IN_PROGRESS", "QUEUED")))] | length' <<<"$current")
	passed=$(jq '[.[] | select(.bucket == "pass" or .state == "SUCCESS")] | length' <<<"$current")
	total=$(jq length <<<"$current")
	conclusion=success
	[[ "$total" -gt 0 ]] || conclusion=no_checks
	[[ "$pending" -eq 0 ]] || conclusion=pending
	[[ $(jq length <<<"$failures") -eq 0 ]] || conclusion=failure
	jq -nc --arg conclusion "$conclusion" --argjson failures "$failures" --argjson checks "$current" --argjson passed "$passed" --argjson pending "$pending" --argjson total "$total" \
		'{event:"ci_ready", conclusion:$conclusion, failures:$failures, checks:$checks, passed:$passed, pending:$pending, total:$total}'
}

emit_conflict
emit_threads

log_file=$(mktemp -t resolve-pr-checks.XXXXXX)
gh pr checks "$PR" --watch --fail-fast >"$log_file" 2>&1 &
check_pid=$!
trap 'kill "$check_pid" 2>/dev/null || true; rm -f "$log_file"' EXIT

while kill -0 "$check_pid" 2>/dev/null; do
	sleep "$COMMENT_INTERVAL"
	emit_conflict
	emit_threads
done

wait "$check_pid" 2>/dev/null || true
rm -f "$log_file"
trap - EXIT
emit_conflict
emit_threads
emit_ci
