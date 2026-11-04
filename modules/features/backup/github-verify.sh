#!/usr/bin/env bash
# Verify the ghorg mirrors and python-github-backup metadata against GitHub, then
# write manifests/<date>/{repos.txt,counts.json,run.log}. The token never appears in
# argv or the manifest. Exits nonzero on any failed check but still writes the
# manifest, so a failed run leaves evidence.
set -euo pipefail
umask 0077

if [ "$#" -lt 4 ] || [ "$#" -gt 5 ]; then
  echo "usage: github-verify.sh <owner> <mirror-root> <meta-dir> <manifest-dir> [--skip-last-update]" >&2
  exit 2
fi

owner="${1,,}"
root="$2"
meta="$3"
manifest="$4"
require_last=1
case "${5:-}" in
  "") ;;
  --skip-last-update) require_last=0 ;;
  *)
    echo "unknown argument: $5" >&2
    exit 2
    ;;
esac

token="${GHORG_GITHUB_TOKEN:?GHORG_GITHUB_TOKEN must point at the token file}"
# Counts can drift between listings and deleted issues stay on disk (pgb never
# prunes), so allow a few per repo; a large drift hides a real gap.
slack="${GITHUB_COUNT_DRIFT:-5}"
fsck_sample="${GITHUB_FSCK_SAMPLE:-5}"
mode="${GITHUB_METADATA_MODE:-daily}"
mirror="$root/${owner}_backup"

install -d -m 0700 "$manifest"
log="$manifest/run.log"
: >>"$log"
fail=0

say() { printf 'github-verify: %s\n' "$*" | tee -a "$log" >&2; }
bad() {
  printf 'github-verify: FAIL: %s\n' "$*" | tee -a "$log" >&2
  fail=1
}

if [ ! -r "$token" ] || [ ! -s "$token" ]; then
  say "token file '$token' is missing, unreadable, or empty"
  exit 1
fi

work=$(mktemp -d)
gh_config=$(mktemp -d)
cleanup() { rm -rf "$work" "$gh_config"; }
trap cleanup EXIT

# GH_TOKEN stays out of command lines; GH_CONFIG_DIR keeps a stray root login out.
export GH_TOKEN
GH_TOKEN=$(cat "$token")
export GH_CONFIG_DIR="$gh_config"

# Forks are out of scope; archived repos are in. `affiliation=owner` matches ghorg's
# clone scope: without it the API returns collaborator/org repos ghorg never mirrors.
if ! gh api --paginate "user/repos?per_page=100&affiliation=owner" \
  --jq '.[] | select(.fork != true) | [.name, .full_name] | @tsv' >"$work/api.tsv"; then
  say "gh api user/repos failed"
  exit 1
fi
sort -u -o "$work/api.tsv" "$work/api.tsv"
cut -f1 "$work/api.tsv" | sort -u >"$work/api.names"

: >"$work/mirror.names"
: >"$work/wiki.names"
if [ -d "$mirror" ]; then
  for dir in "$mirror"/*/; do
    [ -f "$dir/HEAD" ] || continue
    name=$(basename "$dir")
    # Wikis are sibling bare repos named <repo>.wiki (suffix reserved by ghorg).
    case "$name" in
      *.wiki)
        printf '%s\n' "${name%.wiki}" >>"$work/wiki.bases"
        printf '%s\n' "$name" >>"$work/wiki.names"
        ;;
      *) printf '%s\n' "$name" >>"$work/mirror.names" ;;
    esac
  done
  sort -u -o "$work/mirror.names" "$work/mirror.names"
  sort -u -o "$work/wiki.names" "$work/wiki.names"
  if [ -f "$work/wiki.bases" ]; then sort -u -o "$work/wiki.bases" "$work/wiki.bases"; fi
fi

: >"$work/meta.names"
if [ -d "$meta/repositories" ]; then
  for dir in "$meta/repositories"/*/; do
    [ -d "$dir" ] || continue
    basename "$dir"
  done | sort -u >"$work/meta.names"
fi

if [ ! -s "$work/api.names" ]; then
  bad "gh api returned no repositories for '$owner'"
fi

# Missing/extra on either side means the backup no longer describes the account.
check_set() {
  local label="$1" expected="$2" actual="$3" key="$4"
  comm -23 "$expected" "$actual" >"$work/$key.missing"
  comm -13 "$expected" "$actual" >"$work/$key.extra"
  if [ -s "$work/$key.missing" ] || [ -s "$work/$key.extra" ]; then
    bad "$label set mismatch: missing=[$(tr '\n' ' ' <"$work/$key.missing")] extra=[$(tr '\n' ' ' <"$work/$key.extra")]"
  fi
}
check_set "ghorg mirror vs gh api" "$work/api.names" "$work/mirror.names" mirror_vs_api
check_set "pgb metadata vs ghorg mirror" "$work/mirror.names" "$work/meta.names" meta_vs_mirror

# ghorg leaves a wiki directory behind after its parent repo is deleted.
if [ -f "$work/wiki.bases" ]; then
  while IFS= read -r base; do
    [ -n "$base" ] || continue
    if ! grep -qxF "$base" "$work/api.names"; then
      bad "wiki mirror '$base.wiki' has no repo in the gh api listing"
    fi
  done <"$work/wiki.bases"
fi

{
  printf 'name\tin_api\tin_mirror\tin_meta\n'
  sort -u "$work/api.names" "$work/mirror.names" "$work/meta.names" |
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      in_api=no
      in_mirror=no
      in_meta=no
      if grep -qxF "$name" "$work/api.names"; then in_api=yes; fi
      if grep -qxF "$name" "$work/mirror.names"; then in_mirror=yes; fi
      if grep -qxF "$name" "$work/meta.names"; then in_meta=yes; fi
      printf '%s\t%s\t%s\t%s\n' "$name" "$in_api" "$in_mirror" "$in_meta"
    done
} >"$manifest/repos.txt"

# pgb keeps every issue/PR as <number>.json; GraphQL excludes PRs from `issues` and
# counts merged PRs as CLOSED.
: >"$work/counts.tsv"
while IFS= read -r name; do
  [ -n "$name" ] || continue
  if ! grep -qxF "$name" "$work/api.names"; then
    continue
  fi
  full_name=$(awk -F'\t' -v n="$name" '$1==n {print $2; exit}' "$work/api.tsv")
  repo_owner="${full_name%%/*}"
  repo_name="${full_name#*/}"
  pgb_issues=$(find "$meta/repositories/$name/issues" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l)
  pgb_pulls=$(find "$meta/repositories/$name/pulls" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l)
  # shellcheck disable=SC2016  # $owner/$name are GraphQL variables, not shell
  if ! counts=$(gh api graphql \
    -f query='query($owner:String!,$name:String!){repository(owner:$owner,name:$name){issues(states:[OPEN,CLOSED]){totalCount} pullRequests(states:[OPEN,CLOSED,MERGED]){totalCount}}}' \
    -f owner="$repo_owner" -f name="$repo_name" \
    --jq '.data.repository | "\(.issues.totalCount)\t\(.pullRequests.totalCount)"'); then
    bad "GraphQL count failed for $full_name"
    continue
  fi
  api_issues=${counts%%$'\t'*}
  api_pulls=${counts#*$'\t'}

  for kind in issues pulls; do
    case "$kind" in
      issues)
        pgb_count=$pgb_issues
        api_count=$api_issues
        ;;
      pulls)
        pgb_count=$pgb_pulls
        api_count=$api_pulls
        ;;
    esac
    drift=$((pgb_count - api_count))
    if [ "$drift" -lt 0 ]; then drift=$((-drift)); fi
    if [ "$drift" -gt "$slack" ]; then
      bad "$full_name $kind count drift $drift exceeds slack $slack (pgb=$pgb_count api=$api_count)"
    fi
  done

  printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$pgb_issues" "$api_issues" "$pgb_pulls" "$api_pulls" >>"$work/counts.tsv"
done <"$work/meta.names"

# pgb writes a checkpoint per repo/resource every incremental run; an older one means
# it skipped that repo.
if [ "$require_last" = 1 ]; then
  marker="${GITHUB_RUN_MARKER:-}"
  if [ -z "$marker" ] || [ ! -e "$marker" ]; then
    bad "GITHUB_RUN_MARKER is missing; cannot check last_update freshness"
  else
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      for resource in issues pulls; do
        checkpoint="$meta/repositories/$name/$resource/last_update"
        if [ ! -f "$checkpoint" ]; then
          bad "$name/$resource: pgb last_update missing"
        elif [ ! "$checkpoint" -nt "$marker" ]; then
          bad "$name/$resource: pgb last_update is stale for this run"
        fi
      done
    done <"$work/meta.names"
  fi
fi

# Sampling bounds a cold run; set GITHUB_FSCK_SAMPLE to the repo count to check all.
: >"$work/fsck.tsv"
mapfile -t mirror_repos < <(
  cat "$work/mirror.names" "$work/wiki.names" | sort -u
)
mirror_count=${#mirror_repos[@]}
if [ "$mirror_count" -gt 0 ]; then
  step=$(((mirror_count + fsck_sample - 1) / fsck_sample))
  if [ "$step" -lt 1 ]; then step=1; fi
  for ((i = 0; i < mirror_count; i += step)); do
    repo="${mirror_repos[$i]}"
    if git --git-dir="$mirror/$repo" fsck --full --no-progress >/dev/null 2>"$work/fsck.err"; then
      printf '%s\tok\n' "$repo" >>"$work/fsck.tsv"
    else
      printf '%s\tfail\n' "$repo" >>"$work/fsck.tsv"
      bad "git fsck --full failed for $repo: $(tr '\n' ' ' <"$work/fsck.err")"
    fi
  done
fi

names_json() { jq -Rs 'split("\n") | map(select(length > 0))' "$1"; }

jq -n \
  --arg date "$(basename "$manifest")" \
  --arg mode "$mode" \
  --argjson slack "$slack" \
  --argjson api "$(names_json "$work/api.names")" \
  --argjson mirror "$(names_json "$work/mirror.names")" \
  --argjson meta "$(names_json "$work/meta.names")" \
  --argjson mirror_missing "$(names_json "$work/mirror_vs_api.missing")" \
  --argjson mirror_extra "$(names_json "$work/mirror_vs_api.extra")" \
  --argjson meta_missing "$(names_json "$work/meta_vs_mirror.missing")" \
  --argjson meta_extra "$(names_json "$work/meta_vs_mirror.extra")" \
  --argjson fsck "$(jq -Rn '[inputs | split("\t") | {repo: .[0], status: .[1]}]' <"$work/fsck.tsv")" \
  --argjson repos "$(jq -Rn '[inputs | split("\t") | {repo: .[0], issues: {pgb: (.[1] | tonumber), api: (.[2] | tonumber)}, pulls: {pgb: (.[3] | tonumber), api: (.[4] | tonumber)}}]' <"$work/counts.tsv")" \
  '{
    date: $date,
    mode: $mode,
    count_drift_slack: $slack,
    repo_counts: {api: ($api | length), mirror: ($mirror | length), meta: ($meta | length)},
    mismatches: {
      mirror_vs_api: {missing: $mirror_missing, extra: $mirror_extra},
      meta_vs_mirror: {missing: $meta_missing, extra: $meta_extra}
    },
    totals: {
      issues: {
        pgb: ([$repos[].issues.pgb] | add // 0),
        api: ([$repos[].issues.api] | add // 0)
      },
      pulls: {
        pgb: ([$repos[].pulls.pgb] | add // 0),
        api: ([$repos[].pulls.api] | add // 0)
      }
    },
    fsck: {
      checked: $fsck,
      failed: [$fsck[] | select(.status != "ok") | .repo]
    },
    repos: $repos
  }' >"$manifest/counts.json"

if [ "$fail" -ne 0 ]; then
  say "verification failed; see $manifest/run.log"
  exit 1
fi

say "verified ${mirror_count} mirrored repos, $(jq '.repo_counts.meta' "$manifest/counts.json") with metadata, slack $slack"
