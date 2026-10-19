#!/usr/bin/env bash
# Runs the generated ssh-pub-keys against a fake pass-cli: missing .pub files
# are fetched from the Identity vault and trusted in allowed_signers, existing
# ones are left alone, and a failed or malformed fetch writes nothing and exits
# non-zero with a login hint. pass-cli must always see the fs key provider,
# since any other provider force-logs-out the real session.
#
# Usage: ssh_pub_keys.sh <ssh-pub-keys>, with PERSONAL_KEY, WORK_KEY,
# PERSONAL_EMAIL and WORK_EMAIL.
set -euo pipefail

script=$1
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/vault"
failures=0

fail() {
  echo "FAIL $1"
  failures=$((failures + 1))
}

for title in Personal Work; do
  ssh-keygen -q -t ed25519 -N "" -C "$title" -f "$work/vault/$title"
done

# Fake pass-cli: serves $work/vault/<title>.pub for `item view` on the Identity
# vault, or fails / prints malformed output per FAKE_MODE. The shebang is the
# running bash because the Nix sandbox has no /usr/bin/env.
{
  printf '#!%s\n' "$BASH"
  printf 'vault=%q\n' "$work/vault"
  cat <<'EOF'
set -e
[ "${PROTON_PASS_KEY_PROVIDER:-}" = fs ] || { echo "wrong key provider" >&2; exit 3; }
[ "$1 $2" = "item view" ] || { echo "unexpected command: $1 $2" >&2; exit 4; }
shift 2
name= title= field=
while [ $# -gt 0 ]; do
  case "$1" in
    --vault-name) name=$2; shift ;;
    --item-title) title=$2; shift ;;
    --field) field=$2; shift ;;
  esac
  shift
done
[ "$name" = Identity ] && [ "$field" = public_key ] || exit 5
case "${FAKE_MODE:-ok}" in
  ok) cat "$vault/$title.pub" ;;
  fail) echo "Error: This operation requires an authenticated client" >&2; exit 1 ;;
  garbage) echo "Error: Local encryption key not found" ;;
  bare) echo "ssh-ed25519" ;;
  multiline) cat "$vault/$title.pub"; echo "warning: update available" ;;
esac
EOF
} >"$work/bin/pass-cli"
chmod +x "$work/bin/pass-cli"

path() { printf '%s.pub' "${1/#\~/$HOME}"; }

# Runs the script in a fresh-or-given HOME; a provider other than fs in the
# environment must not reach pass-cli. Sets $status.
run() {
  local mode=$1
  export HOME=${2:-$work/home-$mode}
  mkdir -p "$HOME"
  status=0
  env -i PATH="$work/bin:$PATH" HOME="$HOME" PROTON_PASS_KEY_PROVIDER=keyring \
    FAKE_MODE="$mode" "$script" </dev/null 2>"$work/stderr" || status=$?
}

verifies() {
  local title=$1 principal=$2
  echo payload >"$work/msg"
  rm -f "$work/msg.sig"
  ssh-keygen -q -Y sign -f "$work/vault/$title" -n git "$work/msg"
  ssh-keygen -q -Y verify -f "$HOME/.ssh/allowed_signers" -I "$principal" -n git \
    -s "$work/msg.sig" <"$work/msg" >/dev/null 2>&1
}

run ok
((status == 0)) || fail "exited $status when the vault answered"
cmp -s "$(path "$PERSONAL_KEY")" "$work/vault/Personal.pub" || fail "personal .pub not fetched from the Personal item"
cmp -s "$(path "$WORK_KEY")" "$work/vault/Work.pub" || fail "work .pub not fetched from the Work item"
[[ $(stat -c %a "$HOME/.ssh") == 700 ]] || fail "~/.ssh not created 0700"
[[ $(stat -c %a "$(path "$WORK_KEY")") == 644 ]] || fail ".pub not written 0644"
verifies Personal "$PERSONAL_EMAIL" || fail "fetched personal key not trusted as $PERSONAL_EMAIL"
verifies Work "$WORK_EMAIL" || fail "fetched work key not trusted as $WORK_EMAIL"

home=$work/home-keep
mkdir -p "$home/.ssh"
HOME=$home
echo "ssh-ed25519 AAAAexisting existing" >"$(path "$PERSONAL_KEY")"
run ok "$home"
((status == 0)) || fail "exited $status with one key present"
[[ $(cat "$(path "$PERSONAL_KEY")") == "ssh-ed25519 AAAAexisting existing" ]] \
  || fail "existing personal .pub was overwritten"
cmp -s "$(path "$WORK_KEY")" "$work/vault/Work.pub" || fail "missing work .pub not fetched alongside an existing personal one"

home=$work/home-empty
mkdir -p "$home/.ssh"
HOME=$home
: >"$(path "$PERSONAL_KEY")"
run ok "$home"
cmp -s "$(path "$PERSONAL_KEY")" "$work/vault/Personal.pub" || fail "empty personal .pub not refetched"

for mode in fail garbage bare multiline; do
  run "$mode"
  ((status != 0)) || fail "exited 0 when the fetch was $mode"
  # Nothing but the (empty) allowed_signers.
  [[ -z $(find "$HOME" -type f ! -name allowed_signers) ]] || fail "left files behind when the fetch was $mode"
  grep -q "pass-cli login" "$work/stderr" || fail "no login hint when the fetch was $mode"
done

# Without a pass-cli on PATH the baked-in one runs; with no session it fails,
# but it must have been found.
export HOME=$work/home-real
mkdir -p "$HOME"
status=0
env -i PATH="$(dirname "$(command -v ssh-keygen)"):$(dirname "$(command -v cat)")" HOME="$HOME" \
  "$script" </dev/null 2>"$work/stderr" || status=$?
((status != 0)) || fail "exited 0 with no Proton Pass session"
grep -q "command not found" "$work/stderr" && fail "baked-in pass-cli not found"

if ((failures)); then
  echo "$failures ssh-pub-keys expectation(s) failed"
  exit 1
fi
echo "ssh pub keys: ok"
