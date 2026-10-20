#!/usr/bin/env bash
# Run python-github-backup for the mirror owner, verify the result, and write a
# manifest. Called by the GitHub preBackup after ghorg (daily, incremental) and
# by the monthly full service (GITHUB_METADATA_MODE=full).
#
# Usage: github-metadata.sh <owner> <verify-script>
#
# The token is read from GHORG_GITHUB_TOKEN (a root-only 0400 file) and passed
# to pgb as file://URI, so the value never appears in argv. This script is a
# world-readable Nix store path: it must never contain the token.
set -euo pipefail
umask 0077

if [ "$#" -ne 2 ]; then
  echo "usage: github-metadata.sh <owner> <verify-script>" >&2
  exit 2
fi

owner="${1,,}"
verify="$2"
root="${GITHUB_MIRRORS_ROOT:?GITHUB_MIRRORS_ROOT must be set}"
token="${GHORG_GITHUB_TOKEN:?GHORG_GITHUB_TOKEN must point at the token file}"
mode="${GITHUB_METADATA_MODE:-daily}"
meta_lock="${GITHUB_METADATA_LOCK:-/run/lock/github-metadata.lock}"
media_lock="${GITHUB_MEDIA_LOCK:-/run/lock/media-backup.lock}"
date="${BACKUP_DATE:-$(date -u +%F)}"
manifest="$root/manifests/$date"
live_meta="$root/meta"
staged_meta="$root/meta.new"
old_meta="$root/meta.old"

case "$mode" in
  daily)
    target="$live_meta"
    ;;
  full)
    target="$staged_meta"
    ;;
  *)
    echo "github-metadata: unknown GITHUB_METADATA_MODE '$mode'" >&2
    exit 2
    ;;
esac

# pgb treats an unreadable path as the literal token and gets an opaque 401.
if [ ! -r "$token" ] || [ ! -s "$token" ]; then
  echo "github-metadata: token file '$token' is missing, unreadable, or empty" >&2
  exit 1
fi

install -d -m 0700 "$root" "$manifest"
log="$manifest/run.log"
: >"$log"

marker=$(mktemp)
cleanup() {
  rm -f "$marker"
  # Never touch the live meta on failure; remove only the staging tree. An
  # interrupted swap leaves meta.old in place for manual recovery.
  if [ "$mode" = full ]; then
    rm -rf -- "$staged_meta"
  fi
}
trap cleanup EXIT
touch "$marker"
sleep 1

# pgb is single-writer: the monthly full pass must not race the daily run, and
# the swap must not race the driver's copy. The metadata lock serializes pgb;
# the shared host lock is taken only for the swap.
install -d -m 0700 "$(dirname "$meta_lock")"
exec 9>"$meta_lock"
flock 9

if [ "$mode" = full ]; then
  rm -rf -- "$staged_meta"
fi
install -d -m 0700 "$target"

# --issue-timeline does not exist in python-github-backup 0.64.0 (the nixpkgs
# pin); issue events and comments cover the same history. --pull-details is
# required for review/commit metadata and is not implied by --pulls.
flags=(
  -P
  -o "$target"
  --issues
  --issue-comments
  --issue-events
  --pulls
  --pull-comments
  --pull-reviews
  --pull-commits
  --pull-details
  --labels
  --milestones
  --discussions
  --releases
  --assets
  --attachments
  --security-advisories
)
if [ "$mode" = daily ]; then
  flags+=(-i)
fi

# -f/--token-fine rejects anything that does not start with github_pat_ in
# 0.64.0; the documented token here is a classic `repo` PAT, so it goes through
# -t. Detection keeps a future fine-grained token on its supported path.
if [ "$(head -c 11 "$token")" = "github_pat_" ]; then
  flags+=(-f "file://$token")
else
  flags+=(-t "file://$token")
fi

echo "github-metadata: pgb $mode start $(date -u +%FT%TZ) into $target" | tee -a "$log"
if ! github-backup "$owner" "${flags[@]}" 2>&1 | tee -a "$log"; then
  echo "github-metadata: python-github-backup failed" | tee -a "$log" >&2
  exit 1
fi

export GITHUB_RUN_MARKER="$marker"
export GITHUB_METADATA_MODE="$mode"
if [ "$mode" = full ]; then
  bash "$verify" "$owner" "$root" "$target" "$manifest" --skip-last-update
else
  bash "$verify" "$owner" "$root" "$target" "$manifest"
fi

if [ "$mode" = full ]; then
  # A non-incremental run writes no last_update checkpoints. Carry the live
  # ones forward so the next daily run stays incremental instead of doing a
  # full re-fetch; they are older than the staged data, so nothing is missed.
  if [ -d "$live_meta/repositories" ] && [ -d "$target/repositories" ]; then
    for repo_dir in "$target"/repositories/*/; do
      [ -d "$repo_dir" ] || continue
      repo=$(basename "$repo_dir")
      for resource in issues pulls; do
        checkpoint="$live_meta/repositories/$repo/$resource/last_update"
        staged_checkpoint="$repo_dir/$resource/last_update"
        if [ -f "$checkpoint" ] && [ ! -f "$staged_checkpoint" ]; then
          install -d -m 0700 "$repo_dir/$resource"
          cp -p "$checkpoint" "$staged_checkpoint"
        fi
      done
    done
  fi

  # The live meta must never disappear and must never be half-swapped: take the
  # driver's host lock, move the old tree aside, install the verified tree, and
  # restore the old one if that fails.
  (
    exec 8>"$media_lock"
    flock 8
    rm -rf -- "$old_meta"
    if [ -d "$live_meta" ]; then
      mv "$live_meta" "$old_meta"
    fi
    if mv "$target" "$live_meta"; then
      rm -rf -- "$old_meta"
    else
      if [ -d "$old_meta" ]; then
        mv "$old_meta" "$live_meta"
      fi
      exit 1
    fi
  )
  echo "github-metadata: swapped full metadata into $live_meta" | tee -a "$log"
fi

echo "github-metadata: $mode pass complete $(date -u +%FT%TZ)" | tee -a "$log"
