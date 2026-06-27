#!/usr/bin/env bash
set -euo pipefail

mode="watch"
case "${1:-}" in
	watch | verify | reply | resolve | log) mode="$1"; shift ;;
esac

COMMENT_INTERVAL="${COMMENT_INTERVAL:-20}"
case "$COMMENT_INTERVAL" in
	'' | *[!0-9]*) echo "COMMENT_INTERVAL must be seconds" >&2; exit 2 ;;
esac

resolve_pr() {
	local pr="${1:-}"
	[[ -n "$pr" ]] || pr=$(gh pr view --json number -q .number)
	echo "$pr"
}

repo_owner() { gh repo view --json owner -q .owner.login; }
repo_name() { gh repo view --json name -q .name; }
pr_base() { gh pr view "$1" --json baseRefName -q .baseRefName; }

thread_query='query($owner: String!, $repo: String!, $pr: Int!, $endCursor: String) {
  repository(owner: $owner, name: $repo) { pullRequest(number: $pr) {
    reviewThreads(first: 100, after: $endCursor) {
      nodes { id isResolved isOutdated path line startLine diffSide comments(first: 20) { nodes { body author { login } url createdAt } } }
      pageInfo { hasNextPage endCursor }
    }
  } }
}'

threads() {
	gh api graphql --paginate -F owner="$OWNER" -F repo="$REPO" -F pr="$PR" -f query="$thread_query" |
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

ci_event() {
	current=$(checks)
	failures=$(jq -c 'def run_id: ((.link // "") | match("/runs/([0-9]+)")? | .captures[0].string) // ""; [.[] | select(.bucket == "fail" or (.state | IN("FAILURE", "ERROR", "CANCELLED"))) | . + {run_id: run_id}]' <<<"$current")
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

reply() {
	gh api graphql \
		-F thread="$1" \
		-f body="$2" \
		-f query='mutation($thread: ID!, $body: String!) { addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $thread, body: $body}) { comment { url } } }'
}

resolve() {
	gh api graphql \
		-F thread="$1" \
		-f query='mutation($thread: ID!) { resolveReviewThread(input: {threadId: $thread}) { thread { isResolved } } }'
}

log_failed() {
	local run_id="$1"
	[[ "$run_id" =~ ^[0-9]+$ ]] || run_id=$(sed -n 's|.*/runs/\([0-9]*\).*|\1|p' <<<"$run_id")
	[[ -n "$run_id" ]] || { echo "No GitHub Actions run id found" >&2; exit 2; }
	gh run view "$run_id" --log-failed 2>&1 | tail -200
}

case "$mode" in
	reply) reply "$1" "$2"; exit ;;
	resolve) resolve "$1"; exit ;;
	log) log_failed "$1"; exit ;;
esac

PR=$(resolve_pr "${1:-}")
OWNER=$(repo_owner)
REPO=$(repo_name)
BASE=$(pr_base "$PR")

emit_conflict
emit_threads

if [[ "$mode" == verify ]]; then
	event=$(ci_event)
	[[ $(jq -r .conclusion <<<"$event") == success ]] || { echo "$event"; exit 0; }
	jq -nc '{event:"ready"}'
	exit 0
fi

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
ci_event
