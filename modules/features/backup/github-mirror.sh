#!/usr/bin/env bash
# Refresh the bare mirrors of a GitHub owner under GHORG_ABSOLUTE_PATH_TO_CLONE_TO.
#
# Runs as the backup driver's preBackup step, as root, with ghorg/git/git-lfs on
# PATH, GHORG_GITHUB_TOKEN pointing at the runtime token file, and
# GIT_CONFIG_GLOBAL at the checked-in gitconfig that pins packing. This script
# is a world-readable Nix store path, so the token must never appear here.
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: github-mirror.sh <owner>" >&2
  exit 2
fi
owner="$1"
target="${GHORG_ABSOLUTE_PATH_TO_CLONE_TO:?GHORG_ABSOLUTE_PATH_TO_CLONE_TO must be set}"
probe="${GHORG_PROBE_REPO:-}"

# ghorg writes <target>/<owner>_backup/<repo>/; the dataset source is <target>.
# --skip-forks drops upstream duplicates; archived repos ARE mirrored (frozen,
# not disposable); --clone-wiki adds wiki repos; include-submodules is
# deliberately omitted (submodule repos are mirrored on their own). LFS objects
# are pulled because GHORG_FETCH_GIT_LFS is set by the wrapper.
ghorg clone "$owner" \
  --backup \
  --clone-wiki \
  --skip-forks

mirror="$target/${owner}_backup"

# A token without `repo` scope still "succeeds" but silently omits every private
# repo, so probe for one known-private repo and fail loudly when it is absent.
if [ -n "$probe" ] && [ ! -d "$mirror/$probe" ]; then
  echo "github-mirror: probe repo '$probe' missing from $mirror;" \
    "does the token have 'repo' scope?" >&2
  exit 1
fi

echo "github-mirror: refreshed $mirror"
