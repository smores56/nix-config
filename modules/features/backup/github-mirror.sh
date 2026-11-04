#!/usr/bin/env bash
# Refresh the bare mirrors of a GitHub owner under GHORG_ABSOLUTE_PATH_TO_CLONE_TO.
# This script is a world-readable Nix store path: the token must never appear here.
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: github-mirror.sh <owner>" >&2
  exit 2
fi

# ghorg lowercases the output directory but compares the owner case-sensitively.
owner="${1,,}"
target="${GHORG_ABSOLUTE_PATH_TO_CLONE_TO:?GHORG_ABSOLUTE_PATH_TO_CLONE_TO must be set}"
probe="${GHORG_PROBE_REPO:?GHORG_PROBE_REPO must name a known-private repo}"
token="${GHORG_GITHUB_TOKEN:?GHORG_GITHUB_TOKEN must point at the token file}"

# ghorg treats an unreadable path as the literal token and fails with an opaque 401.
if [ ! -r "$token" ] || [ ! -s "$token" ]; then
  echo "github-mirror: token file '$token' is missing, unreadable, or empty" >&2
  exit 1
fi

# The parent is the only barrier for private repo contents: git creates repo dirs 0755.
install -d -m 0700 "$target"

# --skip-forks is policy; archived repos are mirrored; submodule repos are mirrored
# on their own.
refresh() {
  ghorg clone "$owner" \
    --backup \
    --clone-wiki \
    --skip-forks
}

mirror="$target/${owner}_backup"

# A token without `repo` scope still "succeeds" and never prunes private mirrors, so
# directory existence proves nothing; FETCH_HEAD's mtime shows the probe repo was
# listed this run.
marker=$(mktemp)
trap 'rm -f "$marker"' EXIT
touch "$marker"
# Whole-second timestamps: make the marker unambiguously older than this run's writes.
sleep 1

# ghorg exits nonzero if any repo fails; retry once for transient errors.
if ! refresh; then
  echo "github-mirror: ghorg failed; retrying once" >&2
  refresh
fi

if [ ! -f "$mirror/$probe/FETCH_HEAD" ] || [ ! "$mirror/$probe/FETCH_HEAD" -nt "$marker" ]; then
  echo "github-mirror: probe repo '$probe' was not refreshed this run;" \
    "the token may have lost 'repo' scope, or the repo was renamed, forked, or deleted" >&2
  exit 1
fi

# ghorg embeds the token in the origin URL while fetching; a kill in that window can
# leave it in config, so strip it before the copy.
for config in "$mirror"/*/config; do
  [ -f "$config" ] || continue
  url=$(git config --file "$config" --get remote.origin.url 2>/dev/null) || continue
  case "$url" in
    *://*@*)
      rest="${url#*://}"
      git config --file "$config" remote.origin.url "${url%%://*}://${rest#*@}"
      ;;
  esac
done

echo "github-mirror: refreshed $mirror"
