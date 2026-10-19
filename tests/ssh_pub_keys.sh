#!/usr/bin/env bash
# Runs the generated ssh-pub-keys against a fake pass-cli: missing .pub files
# are fetched from the vault, existing ones are left alone, and a failed or
# garbled fetch only warns. pass-cli must always see the fs key provider,
# since any other provider force-logs-out the real session.
#
# Usage: ssh_pub_keys.sh <ssh-pub-keys>, with PERSONAL_KEY and WORK_KEY.
set -euo pipefail

script=$1
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
failures=0

fail() {
  echo "FAIL $1"
  failures=$((failures + 1))
}

# Fake pass-cli: prints a key named after --item-title, or fails / prints an
# error to stdout per FAKE_MODE; refuses to answer without the fs provider.
# The shebang is the running bash because the Nix sandbox has no /usr/bin/env.
{
  printf '#!%s\n' "$BASH"
  cat <<'EOF'
set -e
[ "${PROTON_PASS_KEY_PROVIDER:-}" = fs ] || { echo "wrong key provider" >&2; exit 3; }
title= field=
while [ $# -gt 0 ]; do
  case "$1" in
    --item-title) title=$2; shift ;;
    --field) field=$2; shift ;;
  esac
  shift
done
[ "$field" = public_key ] || exit 4
case "${FAKE_MODE:-ok}" in
  ok) printf 'ssh-ed25519 AAAA%s %s\n' "$title" "$title" ;;
  fail) echo "Error: This operation requires an authenticated client" >&2; exit 1 ;;
  garbage) echo "Error: Local encryption key not found" ;;
esac
EOF
} >"$work/bin/pass-cli"
chmod +x "$work/bin/pass-cli"

# Each case gets a fresh HOME; a provider other than fs in the environment
# must not reach pass-cli.
run() {
  export HOME=$work/home-$1
  mkdir -p "$HOME"
  env -i PATH="$work/bin:$PATH" HOME="$HOME" PROTON_PASS_KEY_PROVIDER=keyring \
    FAKE_MODE="$1" "$script" </dev/null 2>"$work/stderr-$1"
}

path() { printf '%s.pub' "${1/#\~/$HOME}"; }

run ok || fail "exited non-zero when the vault answered"
[[ $(cat "$(path "$PERSONAL_KEY")") == "ssh-ed25519 AAAAPersonal Personal" ]] \
  || fail "personal .pub not fetched from the Personal item"
[[ $(cat "$(path "$WORK_KEY")") == "ssh-ed25519 AAAAWork Work" ]] \
  || fail "work .pub not fetched from the Work item"
[[ $(stat -c %a "$HOME/.ssh" 2>/dev/null || stat -f %Lp "$HOME/.ssh") == 700 ]] \
  || fail "~/.ssh not created 0700"

export HOME=$work/home-keep
mkdir -p "$HOME/.ssh"
echo "ssh-ed25519 AAAAexisting existing" >"$(path "$PERSONAL_KEY")"
env -i PATH="$work/bin:$PATH" HOME="$HOME" FAKE_MODE=ok "$script" </dev/null 2>/dev/null \
  || fail "exited non-zero with one key present"
[[ $(cat "$(path "$PERSONAL_KEY")") == "ssh-ed25519 AAAAexisting existing" ]] \
  || fail "existing personal .pub was overwritten"
[[ -s $(path "$WORK_KEY") ]] || fail "missing work .pub not fetched alongside an existing personal one"

for mode in fail garbage; do
  run "$mode" || fail "exited non-zero when the fetch was $mode"
  # Neither a .pub nor a leftover temp file.
  [[ -z $(find "$HOME" -type f) ]] || fail "left files behind when the fetch was $mode"
  grep -q "pass-cli login" "$work/stderr-$mode" || fail "no login hint when the fetch was $mode"
done

if ((failures)); then
  echo "$failures ssh-pub-keys expectation(s) failed"
  exit 1
fi
echo "ssh pub keys: ok"
