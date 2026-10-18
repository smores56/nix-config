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

# ghorg lowercases the output directory but compares the owner case-sensitively,
# so normalize once here.
owner="${1,,}"
target="${GHORG_ABSOLUTE_PATH_TO_CLONE_TO:?GHORG_ABSOLUTE_PATH_TO_CLONE_TO must be set}"
probe="${GHORG_PROBE_REPO:?GHORG_PROBE_REPO must name a known-private repo}"
token="${GHORG_GITHUB_TOKEN:?GHORG_GITHUB_TOKEN must point at the token file}"

# ghorg treats an unreadable path as the literal token and gets an opaque 401,
# so fail with the real reason first.
if [ ! -r "$token" ] || [ ! -s "$token" ]; then
  echo "github-mirror: token file '$token' is missing, unreadable, or empty" >&2
  exit 1
fi

# The parent is the only barrier for private repo contents: git creates the repo
# dirs 0755, and ghorg only sets 0700 when it creates the target itself.
install -d -m 0700 "$target"

# ghorg writes <target>/<owner>_backup/<repo>/; the dataset source is <target>.
# --skip-forks skips forks by policy (a fork with unique commits is not backed
# up); archived repos ARE mirrored (frozen, not disposable); --clone-wiki adds
# wiki repos; include-submodules is deliberately omitted (submodule repos are
# mirrored on their own). LFS objects are pulled because GHORG_FETCH_GIT_LFS is
# set by the wrapper.
refresh() {
  ghorg clone "$owner" \
    --backup \
    --clone-wiki \
    --skip-forks
}

mirror="$target/${owner}_backup"

# A token without `repo` scope still "succeeds": ghorg lists only public repos
# and never prunes the private mirrors it created earlier. Directory existence
# is therefore not proof — `git remote update` rewrites FETCH_HEAD even when
# nothing changed, so its mtime shows the probe repo was listed *this run*.
marker=$(mktemp)
trap 'rm -f "$marker"' EXIT
touch "$marker"
# Some filesystems timestamp whole seconds; make the marker unambiguously older
# than anything this run writes.
sleep 1

# ghorg exits nonzero if any single repo fails to update. Retry once for the
# transient case, then fail loudly rather than copy a half-advanced mirror.
if ! refresh; then
  echo "github-mirror: ghorg failed; retrying once" >&2
  refresh
fi

if [ ! -f "$mirror/$probe/FETCH_HEAD" ] || [ ! "$mirror/$probe/FETCH_HEAD" -nt "$marker" ]; then
  echo "github-mirror: probe repo '$probe' was not refreshed this run;" \
    "the token may have lost 'repo' scope, or the repo was renamed, forked, or deleted" >&2
  exit 1
fi

# ghorg embeds the token in the origin URL while it fetches and strips it
# afterwards. A kill in that window can leave it in a mirror's config, which the
# copy would then put on the backup disk; strip leftovers before the copy.
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
