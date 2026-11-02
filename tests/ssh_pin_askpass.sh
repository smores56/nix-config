#!/usr/bin/env bash
# askpass must answer only the PIV PIN prompt and never leak the PIN to a
# host-key, presence, or FIDO2 PIN prompt (no FIDO2 credential in use asks for
# one). Usage: ssh_pin_askpass.sh <ssh-pin-askpass>
set -euo pipefail

askpass=$1
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export XDG_RUNTIME_DIR=$work
export DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent
mkdir -p "$work/fido2"

# The cache is a PIN plus the serial:retries snapshot of the card that verified
# it, so the seed and the device below have to agree.
stub=$work/bin
mkdir -p "$stub"
cat >"$stub/ykman" <<'STUB'
#!/bin/sh
case "${1:-} ${2:-}" in
  "fido info") printf 'PIN: 8 attempt(s) remaining\n' ;;
  "fido access") exit 0 ;;
  "list --serials") printf '1234567\n' ;;
  *) exit 1 ;;
esac
STUB
cat >"$stub/fuzzel" <<'STUB'
#!/bin/sh
[ -n "${FUZZEL_FAIL:-}" ] && exit 1
printf '%s' 12345678
STUB
chmod +x "$stub"/*
export FIDO2_YKMAN=$stub/ykman FIDO2_FUZZEL=$stub/fuzzel
unset WAYLAND_DISPLAY DISPLAY

printf '12345678' >"$work/fido2/pin"
chmod 600 "$work/fido2/pin"
printf '1234567:8' >"$work/fido2/pin-state"

fail() {
  echo "FAIL $*" >&2
  exit 1
}

expect_pin() {
  local prompt=$1 out
  out=$("$askpass" "$prompt" 2>/dev/null) || fail "askpass rejected: $prompt"
  [ "$out" = "12345678" ] || fail "wrong answer for: $prompt"
}

# The PIV (PKCS#11) prompt returns the cached PIN.
expect_pin "Enter PIN for 'Yubico YubiKey': "
# A FIDO2 PIN prompt means a verify-required credential nobody enrolled any
# more; it must not receive the PIV PIN.
if out=$("$askpass" "Enter PIN and confirm user presence for ED25519-SK key SHA256:abc: " 2>/dev/null); then
  fail "FIDO2 PIN prompt was answered with: $out"
fi
[ -z "${out:-}" ] || fail "FIDO2 PIN prompt produced output"

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

# No cache and no compositor means a loud failure naming yk-login, not a tty
# prompt and not an empty PIN.
rm -rf "$work/fido2"
if "$askpass" "Enter PIN for 'x': " >/dev/null 2>"$work/err"; then
  fail "missing cache still succeeded"
fi
grep -q 'run yk-login' "$work/err" || fail "missing-cache message does not name yk-login"

# With a reachable compositor the same miss prompts through the shared helper
# and caches the verified PIN instead of failing.
python3 - "$XDG_RUNTIME_DIR/wayland-0" <<'SOCK'
import socket, sys
socket.socket(socket.AF_UNIX).bind(sys.argv[1])
SOCK
expect_pin "Enter PIN for 'x': "
[ "$(cat "$work/fido2/pin")" = 12345678 ] || fail "lazy prompt did not cache the PIN"
[ "$(cat "$work/fido2/pin-state")" = "1234567:8" ] || fail "lazy prompt wrote no snapshot"

# A failing helper must never let a stale cache through as the PIN.
printf '1234567:7' >"$work/fido2/pin-state"
export FUZZEL_FAIL=1
if out=$("$askpass" "Enter PIN for 'x': " 2>/dev/null); then
  fail "a stale cache with a failing prompt still answered"
fi
[ -z "${out:-}" ] || fail "a failing helper printed a PIN: $out"
[ -e "$work/fido2/pin" ] && fail "a stale PIN survived a failed prompt"
unset FUZZEL_FAIL

echo "ssh-pin-askpass ok"
