#!/usr/bin/env bash
# ci-watch.sh — polls CI check-runs and review comments for a GitHub PR.
# Exits on the FIRST actionable event so the agent can wake up, handle it, and re-launch.
#
# Usage: bash ci-watch.sh [PR] [--interval N] [--known-threads "id1,id2,..."]
#
# Events (single JSON line on stdout):
#   {"event":"ci_complete","conclusion":"success"|"failure","failures":[{name,link}],"passed":N}
#   {"event":"new_comments","threads":[...],"known_threads":"id1,id2,..."}
#
# PR, OWNER, REPO auto-detected from current branch/repo if omitted.
set -euo pipefail

PR=""
interval=30
known_threads=""

while [[ $# -gt 0 ]]; do
	case "$1" in
	--interval) interval="$2"; shift 2 ;;
	--known-threads) known_threads="$2"; shift 2 ;;
	--*) echo "Unknown flag: $1" >&2; exit 1 ;;
	*) PR="$1"; shift ;;
	esac
done

if [[ -z "$PR" ]]; then
	PR=$(gh pr view --json number -q '.number' 2>/dev/null) || {
		echo "[ci-watch] No PR found for current branch" >&2
		exit 1
	}
fi

OWNER=$(gh repo view --json owner -q '.owner.login')
NAME=$(gh repo view --json name -q '.name')
SHA=$(gh pr view "$PR" --json headRefOid -q '.headRefOid')

echo "[ci-watch] PR #$PR ($OWNER/$NAME) HEAD ${SHA:0:8} — poll every ${interval}s" >&2

COMMENT_QUERY='query($owner: String!, $repo: String!, $pr: Int!) {
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
}'

fetch_unresolved() {
	gh api graphql \
		-F owner="$OWNER" -F repo="$NAME" -F pr="$PR" \
		-f query="$COMMENT_QUERY" 2>/dev/null |
		jq -c '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)]'
}

stable_count=0
last_total=-1
last_comment=0

while true; do
	now=$(date +%s)

	# --- CI check-runs ---
	raw_runs=$(gh api "repos/$OWNER/$NAME/commits/$SHA/check-runs?per_page=100" 2>/dev/null) || {
		echo "[ci] fetch failed, retrying" >&2
		sleep "$interval"
		continue
	}
	total=$(echo "$raw_runs" | jq '.total_count')
	if [[ "$total" -gt 0 ]]; then
		pending=$(echo "$raw_runs" | jq '[.check_runs[] | select(.status != "completed")] | length')
		completed=$(echo "$raw_runs" | jq '[.check_runs[] | select(.status == "completed")] | length')
		echo "[ci] $completed/$total complete, $pending pending" >&2

		if [[ "$pending" -eq 0 ]]; then
			suites_pending=0
			raw_suites=$(gh api "repos/$OWNER/$NAME/commits/$SHA/check-suites?per_page=100" 2>/dev/null) && {
				suites_pending=$(echo "$raw_suites" | jq '[.check_suites[] | select(.app.slug == "github-actions" and .status != "completed")] | length')
			}
			if [[ "$suites_pending" -eq 0 && "$total" -eq "$last_total" ]]; then
				stable_count=$((stable_count + 1))
			else
				stable_count=0
			fi
			if [[ "$stable_count" -ge 2 ]]; then
				failures=$(echo "$raw_runs" | jq -c '[.check_runs[] | select(.conclusion == "failure") | {name, link: .html_url}]')
				passed=$(echo "$raw_runs" | jq '[.check_runs[] | select(.conclusion == "success")] | length')
				conclusion="success"
				[[ $(echo "$failures" | jq 'length') -gt 0 ]] && conclusion="failure"
				echo "{\"event\":\"ci_complete\",\"conclusion\":\"$conclusion\",\"failures\":$failures,\"passed\":$passed}"
				exit 0
			fi
		else
			stable_count=0
		fi
		last_total=$total
	else
		echo "[ci] no check runs yet" >&2
	fi

	# --- Review comments ---
	if (( now - last_comment >= interval )); then
		threads=$(fetch_unresolved || echo "[]")
		thread_count=$(echo "$threads" | jq 'length')

		if [[ -n "$known_threads" ]]; then
			known_json=$(echo "$known_threads" | jq -R 'split(",") | map(select(. != ""))')
			new_threads=$(echo "$threads" | jq -c --argjson known "$known_json" '[.[] | select(.id as $id | $known | index($id) | not)]')
		else
			new_threads="$threads"
		fi
		new_count=$(echo "$new_threads" | jq 'length')
		echo "[comments] $thread_count unresolved, $new_count new" >&2

		if [[ "$new_count" -gt 0 ]]; then
			new_ids=$(echo "$new_threads" | jq -r '.[].id' | paste -sd ',' -)
			if [[ -n "$known_threads" ]]; then
				updated_known="${known_threads},${new_ids}"
			else
				updated_known="$new_ids"
			fi
			echo "{\"event\":\"new_comments\",\"threads\":$new_threads,\"known_threads\":\"$updated_known\"}"
			exit 0
		fi
		last_comment=$now
	fi

	sleep "$interval"
done
