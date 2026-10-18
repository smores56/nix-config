#!/usr/bin/env bash
# github-mirror.sh must prove the probe repo was refreshed this run, not merely
# that a directory from an earlier run still exists.
set -euo pipefail

script="$1"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/target"
printf 'token\n' > "$work/token"

# Fake ghorg: creates the private probe mirror (with a token-bearing origin) only
# when FAKE_REFRESH=1, mimicking a token that still sees private repos. The
# shebang is the running bash because the Nix sandbox has no /usr/bin/env.
{
  printf '#!%s\n' "$BASH"
  cat <<'EOF'
set -e
owner="$2"
mirror="$GHORG_ABSOLUTE_PATH_TO_CLONE_TO/${owner}_backup"
mkdir -p "$mirror/public"
if [ "${FAKE_REFRESH:-1}" = 1 ]; then
  mkdir -p "$mirror/private"
  git init -q --bare "$mirror/private"
  git --git-dir="$mirror/private" config remote.origin.url \
    'https://x-access-token:SECRET@github.com/o/private.git'
  touch "$mirror/private/FETCH_HEAD"
fi
EOF
} > "$work/bin/ghorg"
chmod +x "$work/bin/ghorg"

run() {
  env -i PATH="$work/bin:$PATH" HOME=/root FAKE_REFRESH="$1" \
    GHORG_GITHUB_TOKEN="$work/token" \
    GHORG_ABSOLUTE_PATH_TO_CLONE_TO="$work/target" \
    GHORG_PROBE_REPO=private \
    bash "$script" owner
}

# A stale private mirror must not satisfy the probe.
if run 0 2>"$work/err"; then
  echo "stale probe passed" >&2
  exit 1
fi
grep -q "was not refreshed" "$work/err"

# A refreshed probe passes, and the token-bearing origin is scrubbed before the
# driver copies the tree.
run 1
url=$(git config --file "$work/target/owner_backup/private/config" --get remote.origin.url)
[ "$url" = "https://github.com/o/private.git" ]

# A missing token fails before ghorg runs.
if env -i PATH="$work/bin:$PATH" GHORG_GITHUB_TOKEN="$work/missing" \
  GHORG_ABSOLUTE_PATH_TO_CLONE_TO="$work/target" GHORG_PROBE_REPO=private \
  bash "$script" owner 2>"$work/err"; then
  echo "missing token passed" >&2
  exit 1
fi
grep -q "missing, unreadable, or empty" "$work/err"

echo "github-mirror probe checks passed"
