#!/usr/bin/env bash
# github-metadata.sh must run pgb with the documented flags, pass the token by
# file (never argv), write the manifest, fail on verification drift, and swap a
# verified full pass into place without touching the live meta on failure.
#
# Hermetic: fake github-backup and gh, real git for the bare mirrors and fsck.
set -euo pipefail

metadata="$1"
verify="$2"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/root/owner_backup" "$work/home"
secret="SECRET-TOKEN-VALUE"
printf '%s\n' "$secret" >"$work/token"
printf 'github_pat_fine_%s\n' "$secret" >"$work/token-fine"

# Two bare mirrors, so the mirror set exists independently of pgb.
for repo in repo-a repo-b; do
  git init -q --bare "$work/root/owner_backup/$repo"
done
# ghorg --clone-wiki writes a sibling <repo>.wiki bare mirror, which is not an
# API repo and must not fail the repo-set check.
git init -q --bare "$work/root/owner_backup/repo-a.wiki"

# Fake gh: already-filtered TSV for user/repos, and the --jq-rendered TSV for
# the GraphQL count query. Knobs simulate a listing gap and a count mismatch.
{
  printf '#!%s\n' "$BASH"
  cat <<'EOF'
set -euo pipefail
[ "${1:-}" = api ] || { echo "fake gh: unexpected args: $*" >&2; exit 2; }
shift
case "$*" in
  *graphql*)
    name=""
    for arg in "$@"; do
      case "$arg" in
        name=*) name="${arg#name=}" ;;
      esac
    done
    case "$name" in
      repo-a)
        printf '%s\t%s\n' "${FAKE_GH_ISSUES_A:-3}" "${FAKE_GH_PULLS_A:-2}"
        ;;
      repo-b)
        printf '%s\t%s\n' "${FAKE_GH_ISSUES_B:-0}" "${FAKE_GH_PULLS_B:-0}"
        ;;
      *)
        echo "fake gh: unknown repo $name" >&2
        exit 1
        ;;
    esac
    ;;
  *user/repos*)
    [ "${FAKE_GH_MISSING:-0}" = 1 ] || printf 'repo-a\towner/repo-a\n'
    printf 'repo-b\towner/repo-b\n'
    ;;
  *)
    echo "fake gh: unexpected args: $*" >&2
    exit 2
    ;;
esac
EOF
} >"$work/bin/gh"

# Fake github-backup: records argv, refuses a token in argv, creates the pgb
# layout with per-repo issue/pull JSON and (incremental only) checkpoints.
{
  printf '#!%s\n' "$BASH"
  cat <<'EOF'
set -euo pipefail
args=("$@")
printf '%s\n' "${args[@]}" >"$FAKE_PGB_ARGS"
out=""
incremental=0
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[i]}" in
    -o) out="${args[i + 1]}" ;;
    -i) incremental=1 ;;
  esac
done
for arg in "${args[@]}"; do
  if [ "$arg" = "$FAKE_TOKEN_SECRET" ]; then
    echo "fake pgb: token value reached argv" >&2
    exit 9
  fi
done
[ -n "$out" ] || { echo "fake pgb: no -o" >&2; exit 2; }
counts_a=${FAKE_ISSUES_A:-3}
pulls_a=${FAKE_PULLS_A:-2}
for repo in repo-a repo-b; do
  mkdir -p "$out/repositories/$repo/issues" "$out/repositories/$repo/pulls"
done
for ((n = 1; n <= counts_a; n++)); do : >"$out/repositories/repo-a/issues/$n.json"; done
for ((n = 1; n <= pulls_a; n++)); do : >"$out/repositories/repo-a/pulls/$n.json"; done
if [ "$incremental" = 1 ] && [ "${FAKE_PGB_STALE:-0}" != 1 ]; then
  for repo in repo-a repo-b; do
    for resource in issues pulls; do
      printf '2026-10-20T00:00:00Z\n' >"$out/repositories/$repo/$resource/last_update"
    done
  done
fi
EOF
} >"$work/bin/github-backup"
chmod +x "$work/bin/gh" "$work/bin/github-backup"

run() {
  env -i \
    PATH="$work/bin:$PATH" \
    HOME="$work/home" \
    GHORG_GITHUB_TOKEN="${TOKEN_FILE:-$work/token}" \
    GITHUB_MIRRORS_ROOT="$work/root" \
    GITHUB_METADATA_LOCK="$work/metadata.lock" \
    GITHUB_MEDIA_LOCK="$work/media.lock" \
    GITHUB_COUNT_DRIFT=1 \
    GITHUB_FSCK_SAMPLE=3 \
    BACKUP_DATE=2026-10-20 \
    FAKE_PGB_ARGS="$work/pgb.args" \
    FAKE_TOKEN_SECRET="$secret" \
    "$@" \
    bash "$metadata" owner "$verify"
}

manifest="$work/root/manifests/2026-10-20"

# Daily success: flags, path, manifest, and counts.
run
[ -f "$manifest/repos.txt" ]
[ -f "$manifest/counts.json" ]
[ -f "$manifest/run.log" ]
grep -qx -- '--issues' "$work/pgb.args"
grep -qx -- '--issue-comments' "$work/pgb.args"
grep -qx -- '--issue-events' "$work/pgb.args"
grep -qx -- '--pulls' "$work/pgb.args"
grep -qx -- '--pull-comments' "$work/pgb.args"
grep -qx -- '--pull-reviews' "$work/pgb.args"
grep -qx -- '--pull-commits' "$work/pgb.args"
grep -qx -- '--pull-details' "$work/pgb.args"
grep -qx -- '--labels' "$work/pgb.args"
grep -qx -- '--milestones' "$work/pgb.args"
grep -qx -- '--discussions' "$work/pgb.args"
grep -qx -- '--releases' "$work/pgb.args"
grep -qx -- '--assets' "$work/pgb.args"
grep -qx -- '--attachments' "$work/pgb.args"
grep -qx -- '--security-advisories' "$work/pgb.args"
grep -qx -- '-P' "$work/pgb.args"
grep -qx -- '-i' "$work/pgb.args"
grep -qx -- "-t" "$work/pgb.args"
grep -qx -- "file://$work/token" "$work/pgb.args"
grep -qx -- "$work/root/meta" "$work/pgb.args"
if grep -qx -- '--issue-timeline' "$work/pgb.args"; then
  echo "unsupported --issue-timeline was passed" >&2
  exit 1
fi
[ -f "$work/root/meta/repositories/repo-a/issues/last_update" ]
jq -e '.mode == "daily"' "$manifest/counts.json" >/dev/null
jq -e '.repo_counts == {api: 2, mirror: 2, meta: 2}' "$manifest/counts.json" >/dev/null
jq -e '.repos[] | select(.repo == "repo-a") | .issues.pgb == 3 and .issues.api == 3' \
  "$manifest/counts.json" >/dev/null
jq -e '.totals.issues.api == 3 and .totals.pulls.api == 2' "$manifest/counts.json" >/dev/null
jq -e '.fsck.failed == []' "$manifest/counts.json" >/dev/null
jq -e '.fsck.checked | map(.repo) | index("repo-a.wiki") != null' "$manifest/counts.json" >/dev/null
grep -q 'repo-a' "$manifest/repos.txt"

# A fine-grained token uses -f (classic keeps -t, asserted above).
TOKEN_FILE="$work/token-fine" run
grep -qx -- '-f' "$work/pgb.args"
if grep -qx -- '-t' "$work/pgb.args"; then
  echo "fine-grained token also passed -t" >&2
  exit 1
fi

# A stale checkpoint fails the run.
if run FAKE_PGB_STALE=1 2>"$work/err"; then
  echo "stale metadata passed" >&2
  exit 1
fi
grep -q "last_update is stale" "$work/err"

# A repo-set gap fails the run.
if run FAKE_GH_MISSING=1 2>"$work/err"; then
  echo "repo-set mismatch passed" >&2
  exit 1
fi
grep -q "set mismatch" "$work/err"

# A count drift beyond the slack fails the run.
if run FAKE_GH_ISSUES_A=9 2>"$work/err"; then
  echo "issue-count drift passed" >&2
  exit 1
fi
grep -q "count drift" "$work/err"

# Full pass: no -i, staged under meta.new, then swapped; checkpoints carried
# over so the next daily run stays incremental.
run
: >"$work/root/meta/live-marker"
run GITHUB_METADATA_MODE=full
[ -d "$work/root/meta" ]
[ ! -e "$work/root/meta.new" ]
[ ! -e "$work/root/meta.old" ]
[ ! -e "$work/root/meta/live-marker" ]
[ -f "$work/root/meta/repositories/repo-a/issues/last_update" ]
grep -qx -- "$work/root/meta.new" "$work/pgb.args"
if grep -qx -- '-i' "$work/pgb.args"; then
  echo "full pass was incremental" >&2
  exit 1
fi
jq -e '.mode == "full"' "$manifest/counts.json" >/dev/null

# A failed full pass keeps the live meta and removes the staging tree.
: >"$work/root/meta/live-marker"
if run GITHUB_METADATA_MODE=full FAKE_GH_ISSUES_A=9 2>"$work/err"; then
  echo "failed full pass swapped anyway" >&2
  exit 1
fi
[ -f "$work/root/meta/live-marker" ]
[ ! -e "$work/root/meta.new" ]
[ ! -e "$work/root/meta.old" ]

echo "github metadata checks passed"
