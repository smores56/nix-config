#!/usr/bin/env bash
# fido2-ensure-pin must prompt once per session, verify before caching, and
# refuse to spend device retries. Usage: fido2_ensure_pin.sh <fido2-ensure-pin>
set -euo pipefail

ensure=$1
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

stub=$work/bin
mkdir -p "$stub" "$work/state"
export XDG_RUNTIME_DIR=$work/runtime
export TEST_WORK=$work
export FIDO2_YKMAN=$stub/ykman
export FIDO2_FUZZEL=$stub/fuzzel
export FIDO2_NOTIFY=$stub/notify-send
# Discovery must not depend on the caller's environment by default.
unset WAYLAND_DISPLAY DISPLAY

fail() {
  echo "FAIL $*" >&2
  exit 1
}

cat >"$stub/notify-send" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_WORK/notify"
exit 0
EOF

# Stands in for the token: `fido info` reports the retry counter, and
# `fido access verify-pin` accepts only the enrolled PIN. A successful
# verification resets the counter to the device maximum (8), which is what the
# real CTAP getPinToken does.
cat >"$stub/ykman" <<'EOF'
#!/bin/sh
set -eu
state=$TEST_WORK/state
[ -f "$state/absent" ] && { echo "error: no YubiKey found" >&2; exit 1; }
case "${1:-}" in
  list)
    [ "${2:-}" = --serials ] || exit 1
    [ -f "$state/no-serial" ] && exit 1
    cat "$state/serial"
    ;;
  fido)
    case "${2:-}" in
      info)
        if [ -f "$state/blocked" ]; then
          printf 'PIN: Blocked\n'
        else
          printf 'PIN: %s attempt(s) remaining\n' "$(cat "$state/retries")"
        fi
        ;;
      access)
        [ "${3:-}" = verify-pin ] && [ "${4:-}" = --pin ] || exit 1
        if [ "$5" = "$(cat "$state/pin")" ]; then
          printf '8' >"$state/retries"
          exit 0
        fi
        n=$(cat "$state/retries")
        printf '%s' "$((n - 1))" >"$state/retries"
        exit 1
        ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
EOF

# Records which compositor the prompt was asked for and answers TEST_PIN.
cat >"$stub/fuzzel" <<'EOF'
#!/bin/sh
printf '%s\n' "${WAYLAND_DISPLAY:-}" >>"$TEST_WORK/prompts"
[ -n "${TEST_DELAY:-}" ] && sleep "$TEST_DELAY"
[ -n "${TEST_EMPTY_OK:-}" ] && exit 0
[ -n "${TEST_PIN:-}" ] || exit 130
printf '%s' "$TEST_PIN"
EOF
chmod +x "$stub"/*

# A live socket, because discovery must reject stale names in the environment.
mkwayland() {
  python3 - "$XDG_RUNTIME_DIR/wayland-$1" <<'EOF'
import socket, sys
socket.socket(socket.AF_UNIX).bind(sys.argv[1])
EOF
}

reset() {
  rm -rf "$XDG_RUNTIME_DIR" "$work/state" "$work/prompts" "$work/notify"
  mkdir -p "$XDG_RUNTIME_DIR" "$work/state"
  printf '5' >"$work/state/retries"
  printf '12345678' >"$work/state/pin"
  printf '1234567' >"$work/state/serial"
  unset TEST_PIN TEST_DELAY TEST_EMPTY_OK YK_ENSURE_NO_PROMPT WAYLAND_DISPLAY DISPLAY
}

pin_file=$XDG_RUNTIME_DIR/fido2/pin
state_file=$XDG_RUNTIME_DIR/fido2/pin-state

# A first use prompts, verifies, and caches. The snapshot is the post-verify
# state, because a successful verification refunds the retry counter.
reset
mkwayland 0
export TEST_PIN=12345678
"$ensure" || fail "cache miss should prompt and succeed"
[ "$(cat "$pin_file")" = 12345678 ] || fail "PIN was not cached"
[ "$(stat -c %a "$pin_file")" = 600 ] || fail "cached PIN is not 0600"
[ "$(cat "$state_file")" = "$(cat "$work/state/serial"):8" ] ||
  fail "snapshot is not serial:post-verify-counter (got $(cat "$state_file" 2>/dev/null))"
[ "$(wc -l <"$work/prompts")" -eq 1 ] || fail "expected exactly one prompt"
[ "$(cat "$work/prompts")" = wayland-0 ] || fail "prompt did not use the discovered socket"

# A warm cache costs no prompt, and stays warm on later logins.
: >"$work/prompts"
"$ensure" || fail "warm cache should succeed"
"$ensure" || fail "warm cache should keep succeeding"
[ -s "$work/prompts" ] && fail "warm cache prompted again"

# The environment inherited by the agent may name a socket from an old
# session; discovery has to fall back to the live one.
reset
mkwayland 0
export WAYLAND_DISPLAY=wayland-9 TEST_PIN=12345678
"$ensure" || fail "stale WAYLAND_DISPLAY should fall back to the live socket"
[ "$(cat "$work/prompts")" = wayland-0 ] || fail "stale WAYLAND_DISPLAY was trusted"

# An absolute WAYLAND_DISPLAY is a path, not a name in the runtime dir.
reset
mkwayland 0
export WAYLAND_DISPLAY=$XDG_RUNTIME_DIR/wayland-0 TEST_PIN=12345678
"$ensure" || fail "absolute WAYLAND_DISPLAY should work"
[ "$(cat "$work/prompts")" = "$XDG_RUNTIME_DIR/wayland-0" ] ||
  fail "absolute WAYLAND_DISPLAY was rewritten"

# With no usable name, the newest live socket wins over the older one.
reset
mkwayland 0
mkwayland 1
export TEST_PIN=12345678
"$ensure" || fail "newest socket should be used"
[ "$(cat "$work/prompts")" = wayland-1 ] || fail "newest socket was not preferred"

# Below four retries the PIN is not sent at all, and the message says what to
# do instead of pointing at a tool that would also refuse.
reset
mkwayland 0
printf '2' >"$work/state/retries"
export TEST_PIN=12345678
if "$ensure" 2>"$work/err"; then fail "should refuse with two retries left"; fi
grep -q 'ykman fido access verify-pin' "$work/err" ||
  fail "low-retry message does not name the manual verification"
[ -e "$pin_file" ] && fail "cached a PIN while retries were low"
[ -e "$work/prompts" ] && fail "prompted while retries were low"

# A blocked PIN is not "PIN not set".
reset
mkwayland 0
touch "$work/state/blocked"
export TEST_PIN=12345678
if "$ensure" 2>"$work/err"; then fail "should refuse a blocked PIN"; fi
grep -q 'blocked' "$work/err" || fail "blocked PIN is not reported as blocked"
[ -e "$work/prompts" ] && fail "prompted for a blocked PIN"

# --quiet suppresses the desktop notification but not the failure.
reset
mkwayland 0
printf '2' >"$work/state/retries"
export TEST_PIN=12345678
if "$ensure" --quiet; then fail "should still fail quietly"; fi
[ -e "$work/notify" ] && fail "--quiet still notified"

# A rejected PIN caches nothing and is visible to the caller.
reset
mkwayland 0
export TEST_PIN=00000000
if "$ensure"; then fail "should fail when the card rejects the PIN"; fi
[ -e "$pin_file" ] && fail "cached a rejected PIN"
[ -e "$state_file" ] && fail "wrote a snapshot for a rejected PIN"
[ "$(cat "$work/state/retries")" = 4 ] || fail "stub did not see the retry burned"
[ "$(wc -l <"$work/prompts")" -eq 1 ] || fail "expected one prompt for a rejection"

# An empty answer with a zero exit is not a PIN.
reset
mkwayland 0
export TEST_EMPTY_OK=1
if "$ensure"; then fail "should reject an empty answer"; fi
[ -e "$pin_file" ] && fail "cached an empty PIN"

# A retry spent since the cache was written means the cache may be wrong.
reset
mkwayland 0
export TEST_PIN=12345678
"$ensure" || fail "initial cache should succeed"
printf '4' >"$work/state/retries"
"$ensure" || fail "stale cache should re-prompt and succeed"
[ "$(wc -l <"$work/prompts")" -eq 2 ] || fail "stale cache did not re-prompt"
# The verification just refunded the counter, so the next call is warm again.
"$ensure" || fail "post-verify cache should be warm"
[ "$(wc -l <"$work/prompts")" -eq 2 ] ||
  fail "snapshot was taken before the verification refunded the counter"

# A different token with the same counter must not receive the cached PIN.
reset
mkwayland 0
export TEST_PIN=12345678
"$ensure" || fail "initial cache should succeed"
printf '7654321' >"$work/state/serial"
"$ensure" || fail "a swapped token should re-prompt and succeed"
[ "$(wc -l <"$work/prompts")" -eq 2 ] || fail "a swapped token did not re-prompt"
[ "$(cat "$state_file")" = "7654321:8" ] ||
  fail "snapshot was not rebound to the new token"

# Serial-less tokens fall back to the counter guard instead of prompting forever.
reset
mkwayland 0
touch "$work/state/no-serial"
export TEST_PIN=12345678
"$ensure" || fail "serial-less first use should succeed"
[ "$(cat "$state_file")" = "-:8" ] ||
  fail "serial-less snapshot is not '-' plus the counter"
"$ensure" || fail "serial-less warm cache should succeed"
[ "$(wc -l <"$work/prompts")" -eq 1 ] || fail "serial-less cache prompted again"

# A card that cannot be probed right now (busy, or briefly unplugged) must
# not turn a verified cache into a failed login.
reset
mkwayland 0
export TEST_PIN=12345678
"$ensure" || fail "initial cache should succeed"
touch "$work/state/absent"
"$ensure" || fail "a failed probe should keep the verified cache"
[ "$(wc -l <"$work/prompts")" -eq 1 ] || fail "a failed probe re-prompted"

# A cancelled re-prompt must leave nothing that could be replayed.
reset
mkwayland 0
export TEST_PIN=12345678
"$ensure" || fail "initial cache should succeed"
printf '4' >"$work/state/retries"
unset TEST_PIN
if "$ensure"; then fail "a cancelled re-prompt should fail"; fi
[ -e "$pin_file" ] && fail "a stale PIN survived a cancelled re-prompt"

# No compositor: fail closed and say what still works.
reset
export TEST_PIN=12345678
if "$ensure" 2>"$work/err"; then fail "should fail without a compositor"; fi
grep -q 'run yk-login' "$work/err" || fail "no-compositor message does not name yk-login"
[ -e "$work/prompts" ] && fail "prompted without a compositor"
[ -e "$pin_file" ] && fail "cached without a compositor"

# Unattended callers never get an unannounced dialog, but a warm cache is fine.
reset
mkwayland 0
export TEST_PIN=12345678 YK_ENSURE_NO_PROMPT=1
if "$ensure" 2>"$work/err"; then fail "should fail when prompting is disabled"; fi
grep -q 'run yk-login' "$work/err" || fail "disabled-prompt message does not name yk-login"
[ -e "$work/prompts" ] && fail "prompted while prompting was disabled"
unset YK_ENSURE_NO_PROMPT
"$ensure" || fail "prompt should succeed once enabled"
export YK_ENSURE_NO_PROMPT=1
"$ensure" || fail "a warm cache must work when prompting is disabled"
[ "$(wc -l <"$work/prompts")" -eq 1 ] || fail "warm cache prompted again"

# Malformed input is never sent to the card.
reset
mkwayland 0
export TEST_PIN=1234
if "$ensure"; then fail "should reject a short PIN"; fi
[ -e "$pin_file" ] && fail "cached a malformed PIN"
[ "$(cat "$work/state/retries")" = 5 ] || fail "sent a malformed PIN to the card"

# No card: no dialog, no cache, no burned retry.
reset
mkwayland 0
touch "$work/state/absent"
export TEST_PIN=12345678
if "$ensure"; then fail "should fail without a card"; fi
[ -e "$work/prompts" ] && fail "prompted without a card"

# Two callers racing must not produce two dialogs.
reset
mkwayland 0
export TEST_PIN=12345678 TEST_DELAY=0.5
"$ensure" & first=$!
"$ensure" & second=$!
wait "$first" || fail "first racing caller failed"
wait "$second" || fail "second racing caller failed"
[ "$(wc -l <"$work/prompts")" -eq 1 ] ||
  fail "racing callers opened $(wc -l <"$work/prompts") dialogs"

# --tty is the recovery path when there is no compositor at all.
reset
export TEST_PIN=12345678
python3 - "$ensure" <<'EOF' || fail "recovery on a tty should succeed"
import os, pty, sys
exe = sys.argv[1]
pid, fd = pty.fork()
if pid == 0:
    os.execv(exe, [exe, "--tty"])
os.write(fd, b"12345678\n")
while True:
    try:
        if not os.read(fd, 4096):
            break
    except OSError:
        break
_, status = os.waitpid(pid, 0)
sys.exit(os.waitstatus_to_exitcode(status))
EOF
[ "$(cat "$pin_file")" = 12345678 ] || fail "tty prompt did not cache the PIN"
[ -e "$work/prompts" ] && fail "tty mode opened a dialog"

# Nothing the helper prints may look like a PIN on stdout: the askpass's stdout
# is exactly what ssh treats as the PIN.
reset
mkwayland 0
cat >"$stub/notify-send" <<'STUB'
#!/bin/sh
printf 'NOT-A-PIN\n'
exit 0
STUB
chmod +x "$stub/notify-send"
printf '2' >"$work/state/retries"
export TEST_PIN=12345678
out=$("$ensure" 2>/dev/null) && fail "should refuse with two retries left"
[ -z "$out" ] || fail "helper wrote to stdout: $out"

echo "fido2-ensure-pin ok"
