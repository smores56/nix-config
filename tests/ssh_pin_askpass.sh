#!/usr/bin/env bash
# askpass must answer only the two PIN prompt shapes and never leak the PIN to
# a host-key or presence prompt. Usage: ssh_pin_askpass.sh <ssh-pin-askpass>
set -euo pipefail

askpass=$1
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export XDG_RUNTIME_DIR=$work
export DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent
mkdir -p "$work/fido2"
printf '12345678' >"$work/fido2/pin"
chmod 600 "$work/fido2/pin"

fail() {
  echo "FAIL $*" >&2
  exit 1
}

expect_pin() {
  local prompt=$1 out
  out=$("$askpass" "$prompt" 2>/dev/null) || fail "askpass rejected: $prompt"
  [ "$out" = "12345678" ] || fail "wrong answer for: $prompt"
}

# The PKCS#11 prompt and the agent prompt both return the cached PIN.
expect_pin "Enter PIN for 'Yubico YubiKey': "
expect_pin "Enter PIN and confirm user presence for ED25519-SK key SHA256:abc: "

# The host-key confirmation prompt must not receive the PIN.
if out=$("$askpass" 'Are you sure you want to continue connecting (yes/no/[fingerprint])? ' 2>/dev/null); then
  fail "host-key prompt was answered with: $out"
fi
[ -z "${out:-}" ] || fail "host-key prompt produced output"

# A presence request exits 1 and must not print the PIN. notify-send is allowed
# to fail (the test bus is deliberately invalid).
if out=$("$askpass" 'Confirm user presence for key ED25519-SK SHA256:abc' 2>/dev/null); then
  fail "presence prompt was answered with: $out"
fi
[ -z "${out:-}" ] || fail "presence prompt produced output"

# No cache means a loud failure naming yk-login, not a tty prompt.
rm -rf "$work/fido2"
if "$askpass" "Enter PIN for 'x': " >/dev/null 2>"$work/err"; then
  fail "missing cache still succeeded"
fi
grep -q 'run yk-login' "$work/err" || fail "missing-cache message does not name yk-login"

echo "ssh-pin-askpass ok"
