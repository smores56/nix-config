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
[ "$title" = "${FAKE_FAIL_TITLE:-}" ] && { echo "Error: item not found" >&2; exit 1; }
case "${FAKE_MODE:-ok}" in
  ok) cat "$vault/$title.pub" ;;
  fail) echo "Error: This operation requires an authenticated client" >&2; exit 1 ;;
  garbage) echo "Error: Local encryption key not found" ;;
  bare) echo "ssh-ed25519" ;;
  multiline) cat "$vault/$title.pub"; echo "warning: update available" ;;
  options) printf 'from="10.0.0.1" '; cat "$vault/$title.pub" ;;
  crlf) printf '%s\r\n' "$(cat "$vault/$title.pub")" ;;
esac
EOF
} >"$work/bin/pass-cli"
chmod +x "$work/bin/pass-cli"

path() { printf '%s.pub' "${1/#\~/$HOME}"; }

# Each case gets its own HOME.
fresh() {
  export HOME=$work/home-$1
  mkdir -p "$HOME/.ssh"
}

# Runs the script with the fake first on PATH (RUN_PATH overrides); a provider
# other than fs in the environment must not reach pass-cli. Sets $status.
run() {
  status=0
  env -i PATH="${RUN_PATH:-$work/bin:$PATH}" HOME="$HOME" PROTON_PASS_KEY_PROVIDER=keyring \
    FAKE_MODE="$1" FAKE_FAIL_TITLE="${FAKE_FAIL_TITLE:-}" "$script" </dev/null 2>"$work/stderr" || status=$?
}

# ssh_allowed_signers.sh proves entries verify; here the fetched key must be one.
trusted() {
  read -r type body _ <"$work/vault/$1.pub"
  grep -qxF "$2 namespaces=\"git\" $type $body" "$HOME/.ssh/allowed_signers"
}

export HOME=$work/home-new
run ok
((status == 0)) || fail "exited $status when the vault answered"
cmp -s "$(path "$PERSONAL_KEY")" "$work/vault/Personal.pub" || fail "personal .pub not fetched from the Personal item"
cmp -s "$(path "$WORK_KEY")" "$work/vault/Work.pub" || fail "work .pub not fetched from the Work item"
[[ $(stat -c %a "$HOME/.ssh") == 700 ]] || fail "~/.ssh not created 0700"
for key in "$PERSONAL_KEY" "$WORK_KEY"; do
  [[ $(stat -c %a "$(path "$key")") == 644 ]] || fail "$(path "$key") not written 0644"
done
trusted Personal "$PERSONAL_EMAIL" || fail "fetched personal key not trusted as $PERSONAL_EMAIL"
trusted Work "$WORK_EMAIL" || fail "fetched work key not trusted as $WORK_EMAIL"

fresh keep
echo "ssh-ed25519 AAAAexisting existing" >"$(path "$PERSONAL_KEY")"
run ok
((status == 0)) || fail "exited $status with one key present"
[[ $(cat "$(path "$PERSONAL_KEY")") == "ssh-ed25519 AAAAexisting existing" ]] \
  || fail "existing personal .pub was overwritten"
cmp -s "$(path "$WORK_KEY")" "$work/vault/Work.pub" || fail "missing work .pub not fetched alongside an existing personal one"

# home-manager may create ~/.ssh first (for ~/.ssh/config) with the umask.
fresh loose
chmod 755 "$HOME/.ssh"
run ok
[[ $(stat -c %a "$HOME/.ssh") == 700 ]] || fail "existing ~/.ssh not tightened to 0700"

# One item failing must not stop the other from being fetched and trusted.
fresh partial
FAKE_FAIL_TITLE=Work run ok
((status != 0)) || fail "exited 0 with the Work item unavailable"
cmp -s "$(path "$PERSONAL_KEY")" "$work/vault/Personal.pub" || fail "personal .pub not fetched when Work failed"
trusted Personal "$PERSONAL_EMAIL" || fail "personal key not trusted when Work failed"
[[ -e $(path "$WORK_KEY") ]] && fail "wrote a work .pub when its fetch failed"
grep -q "item not found" "$work/stderr" || fail "pass-cli's own error not shown"

fresh empty
: >"$(path "$PERSONAL_KEY")"
run ok
cmp -s "$(path "$PERSONAL_KEY")" "$work/vault/Personal.pub" || fail "empty personal .pub not refetched"

for mode in fail garbage bare multiline options crlf; do
  fresh "$mode"
  run "$mode"
  ((status != 0)) || fail "exited 0 when the fetch was $mode"
  # Nothing but the (empty) allowed_signers.
  [[ -z $(find "$HOME" -type f ! -name allowed_signers) ]] || fail "left files behind when the fetch was $mode"
  grep -q "pass-cli login" "$work/stderr" || fail "no login hint when the fetch was $mode"
done

# Without a pass-cli on PATH the baked-in one runs; with no session it fails,
# but it must have been found.
fresh real
RUN_PATH="$(dirname "$(command -v ssh-keygen)"):$(dirname "$(command -v cat)")" run ok
((status != 0)) || fail "exited 0 with no Proton Pass session"
grep -q "command not found" "$work/stderr" && fail "baked-in pass-cli not found"

if ((failures)); then
  echo "$failures ssh-pub-keys expectation(s) failed"
  exit 1
fi
echo "ssh pub keys: ok"
