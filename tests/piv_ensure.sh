#!/usr/bin/env bash
# piv-ensure, the pre-connect step on both OSes: a no-op on a warm agent; a
# cold agent reloads from the login-session PIN cache without a dialog when the
# card is the one the cache was verified against with an unspent counter;
# otherwise one dialog, one load, and the PIN is cached only after the card
# accepted it. A no-prompt caller never opens a dialog, a low or unreadable
# retry budget never reaches the card, and a failed load is never retried.
# Usage: piv_ensure.sh <piv-ensure.sh> <piv-dialog.sh>
set -euo pipefail

ensure=$1
dialog=$2
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() {
  echo "FAIL $*" >&2
  exit 1
}

mkdir "$work/bin"
log=$work/log
state=$work/state
cache=$work/cache

# ssh-add fake: -T succeeds once `warm` exists. -s asks the PIN through
# SSH_ASKPASS like the real one; a wrong PIN spends a try.
cat >"$work/bin/ssh-add" <<EOF
#!$BASH
case \$1 in
  -T) echo "-T sock=\$SSH_AUTH_SOCK" >>"$state/calls"; [ -e "$state/warm" ] ;;
  -e) echo "-e \$2 sock=\$SSH_AUTH_SOCK" >>"$log"; exit 1 ;;
  -s)
    read -r -t 1 piped || piped=
    echo "-s \$2 require=\$SSH_ASKPASS_REQUIRE sock=\$SSH_AUTH_SOCK piped=\$piped" >>"$log"
    echo "argv \$* env-hits \$(env | grep -c -- "\$(cat "$state/pin")")" >>"$state/calls"
    pin=\$("\$SSH_ASKPASS" "Enter passphrase for PKCS#11: ") || exit 1
    if [ "\$pin" != "\$(cat "$state/pin")" ]; then
      echo \$((\$(cat "$state/tries") - 1)) >"$state/tries"
      exit 1
    fi
    echo 3 >"$state/tries"
    [ -e "$state/load-cold" ] || touch "$state/warm"
    ;;
  *) exit 2 ;;
esac
EOF
cat >"$work/bin/ykman" <<EOF
#!$BASH
echo "ykman \$*" >>"$log"
[ -e "$state/no-card" ] && { echo "ERROR: No YubiKey detected" >&2; exit 2; }
case "\$*" in
  "list --serials") cat "$state/serial" ;;
  "piv info") printf 'PIV version:              5.7.1\nPIN tries remaining:      %s/3\n' "\$(cat "$state/tries")" ;;
  *) exit 2 ;;
esac
EOF
cat >"$work/bin/dialog" <<EOF
#!$BASH
echo dialog >>"$log"
[ -e "$state/slow" ] && sleep 0.5
[ -e "$state/cancel" ] && exit 1
cat "$state/answer"
EOF
cat >"$work/bin/cache-askpass" <<EOF
#!$BASH
cat "\$PIV_PIN_FILE"
EOF
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH"

sock=$work/piv-agent.sock
provider=/nix/store/x-opensc/lib/opensc-pkcs11.so

# reset [flags...]: a cold agent, an empty cache, one card with 3 tries.
reset() {
  rm -rf "$state" "$log" "$cache"
  mkdir "$state"
  : >"$log"
  echo 3 >"$state/tries"
  echo 12345678 >"$state/pin"
  echo 12345678 >"$state/answer"
  echo 111 >"$state/serial"
  rm -f "$sock"
  python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$sock"
  for f in "$@"; do touch "$state/$f"; done
}
printf 'PIN-FROM-PIPE\n' >"$work/stdin"
run() {
  env -u YK_ENSURE_NO_PROMPT SSH_AUTH_SOCK=/ambient/agent "$@" \
    bash "$ensure" "$sock" "$provider" "$cache" "$work/bin/dialog" "$work/bin/cache-askpass" \
    "$work/k1.pub" "$work/k2.pub" <"$work/stdin"
}
umask 000
loads() { grep -c '^-s ' "$log" || true; }
dialogs() { grep -c '^dialog$' "$log" || true; }
cold() { rm -f "$state/warm"; : >"$log"; }

reset warm
run || fail "warm agent failed"
[ ! -s "$log" ] || fail "warm agent touched the card: $(cat "$log")"
! grep -q "sock=/ambient/agent" "$state/calls" || fail "health check used the caller's agent"

# First use: one dialog, one forced load with empty stdin, then a 0600 cache.
reset
run || fail "cold agent did not load"
[ "$(dialogs)" = 1 ] || fail "first use opened $(dialogs) dialogs"
[ "$(loads)" = 1 ] || fail "first use loaded $(loads) times"
grep -q "^-e $provider" "$log" || fail "stale provider not removed first"
! grep -q "sock=/ambient/agent" "$log" "$state/calls" || fail "used the caller's agent"
! grep -q 12345678 "$state/calls" || fail "PIN reached ssh-add argv"
grep -q "env-hits 0" "$state/calls" || fail "PIN reached ssh-add's environment"
grep -q "^-s $provider require=force sock=$sock piped=$" "$log" ||
  fail "load not forced through the askpass with empty stdin: $(cat "$log")"
[ "$(cat "$cache/pin")" = 12345678 ] || fail "verified PIN not cached"
[ "$(stat -c %a "$cache/pin" 2>/dev/null || stat -f %Lp "$cache/pin")" = 600 ] || fail "cache is not 0600"
[ "$(stat -c %a "$cache" 2>/dev/null || stat -f %Lp "$cache")" = 700 ] || fail "cache dir is not 0700"

# Sleep, unplug, or a lock-screen PIV unlock: the agent goes cold, the card is
# unchanged, so the cache reloads it with no dialog.
cold
run || fail "cached PIN did not reload a cold agent"
[ "$(dialogs)" = 0 ] || fail "cached reload opened a dialog"
[ "$(loads)" = 1 ] || fail "cached reload loaded $(loads) times"

# Unattended callers reload from the cache too.
cold
run YK_ENSURE_NO_PROMPT=1 || fail "no-prompt caller could not use the cache"
[ "$(dialogs)" = 0 ] || fail "no-prompt caller opened a dialog"

# A spent try since caching: the cached PIN is not replayed.
cold
echo 2 >"$state/tries"
run || fail "stale cache did not fall back to a prompt"
[ "$(dialogs)" = 1 ] || fail "counter change did not re-prompt"
[ "$(loads)" = 1 ] || fail "counter change loaded $(loads) times"
cold
run || fail "re-cached PIN did not reload"
[ "$(dialogs)" = 0 ] || fail "PIN cached after a spent try re-prompts every time"

# A different card: the cached PIN is not replayed.
cold
echo 222 >"$state/serial"
run || fail "card swap did not fall back to a prompt"
[ "$(dialogs)" = 1 ] || fail "card swap did not re-prompt"

# A stale cache with no prompt allowed fails without touching the card.
cold
echo 333 >"$state/serial"
if run YK_ENSURE_NO_PROMPT=1 2>/dev/null; then fail "no-prompt caller replayed a stale cache"; fi
[ "$(loads)" = 0 ] || fail "stale no-prompt run reached ssh-add -s"
[ ! -e "$cache/pin" ] || fail "stale cache kept after it was rejected"

reset
if run YK_ENSURE_NO_PROMPT=1 2>/dev/null; then fail "no-prompt caller loaded without a cache"; fi
[ "$(dialogs)" = 0 ] || fail "no-prompt caller opened a dialog"
[ "$(loads)" = 0 ] || fail "no-prompt caller reached ssh-add -s"

# A caller's SSH_ASKPASS is never used: only the cache answers ssh-add.
reset
run SSH_ASKPASS=/caller/askpass || fail "caller askpass broke the load"
[ "$(dialogs)" = 1 ] || fail "caller askpass replaced the dialog"

# A stopped agent is reported as such and keeps the cache.
reset
run >/dev/null || fail "setup load failed"
cold
rm "$sock"
out=$(run 2>&1) && fail "missing agent socket reported success"
[[ $out == *"not running"* ]] || fail "missing agent not named: '$out'"
[ -e "$cache/pin" ] || fail "missing agent discarded the cache"

reset
echo 1 >"$state/tries"
if run 2>/dev/null; then fail "loaded with one PIN try left"; fi
[ "$(dialogs)$(loads)" = 00 ] || fail "low retry budget reached the dialog or the card"

reset
echo garbage >"$state/tries"
if run 2>/dev/null; then fail "loaded with an unreadable retry count"; fi
[ "$(loads)" = 0 ] || fail "unreadable retry count still reached ssh-add -s"

reset no-card
out=$(run 2>&1) && fail "loaded with no readable card"
[[ $out == *"retry count"* ]] || fail "ykman failure lost its hint: '$out'"
[ "$(loads)" = 0 ] || fail "ykman failure still reached ssh-add -s"

reset cancel
if run 2>/dev/null; then fail "cancelled dialog reported success"; fi
[ "$(loads)" = 0 ] || fail "cancelled dialog still loaded"
[ ! -e "$cache/pin" ] || fail "cancelled dialog left a cache"

for answer in "" 12345 123456789 "1234 567"; do
  reset
  echo "$answer" >"$state/answer"
  if run 2>/dev/null; then fail "accepted PIN '$answer'"; fi
  [ "$(loads)" = 0 ] || fail "malformed PIN '$answer' reached the card"
done

# A wrong PIN: one load, never retried, nothing cached.
reset
echo 87654321 >"$state/answer"
if run 2>/dev/null; then fail "wrong PIN reported success"; fi
[ "$(loads)" = 1 ] || fail "wrong PIN was retried ($(loads) loads)"
[ ! -e "$cache/pin" ] || fail "rejected PIN was cached"

reset load-cold
if run 2>/dev/null; then fail "load that left the agent unusable reported success"; fi
[ ! -e "$cache/pin" ] || fail "unusable load left a cache"

# A matching cache the card now rejects (PIN changed elsewhere): one load,
# no retry, no dialog, cache gone.
reset
run >/dev/null || fail "setup load failed"
cold
echo 87654321 >"$state/pin"
if out=$(run 2>&1); then fail "rejected cached PIN reported success"; fi
[ "$(loads)$(dialogs)" = 10 ] || fail "rejected cached PIN: $(loads) loads, $(dialogs) dialogs"
[ ! -e "$cache/pin" ] || fail "rejected cached PIN kept"
[[ $out != *12345678* ]] || fail "PIN leaked to output"

# Loose permissions left behind are tightened; a symlinked cache dir or PIN
# file is never written through.
reset
mkdir -m 755 "$cache"
run || fail "pre-existing cache dir broke the load"
[ "$(stat -c %a "$cache" 2>/dev/null || stat -f %Lp "$cache")" = 700 ] || fail "loose cache dir not tightened"
reset
mkdir "$work/decoy" 2>/dev/null || true
: >"$work/decoy-pin"
ln -s "$work/decoy" "$cache"
if run 2>/dev/null; then fail "symlinked cache dir accepted"; fi
[ "$(loads)" = 0 ] || fail "symlinked cache dir reached the card"
rm -f "$cache"
reset
mkdir -m 700 "$cache"
ln -s "$work/decoy-pin" "$cache/pin"
run || fail "symlinked pin file broke the load"
[ ! -s "$work/decoy-pin" ] || fail "PIN written through a symlink"

# Accepted PIN shapes: 6 and 8 characters, letters allowed.
for pin in 123456 abcd1234; do
  reset
  echo "$pin" >"$state/pin"
  echo "$pin" >"$state/answer"
  run || fail "rejected valid PIN '$pin'"
done

# Two parallel connections: one dialog, one load; the second re-checks after
# the lock and finds the agent warm.
reset slow
run & first=$!
sleep 0.1
run & second=$!
wait "$first" || fail "first parallel caller failed"
wait "$second" || fail "second parallel caller failed"
[ "$(dialogs)$(loads)" = 11 ] || fail "parallel callers: $(dialogs) dialogs, $(loads) loads"

# Dialog: macOS through osascript (PIV_OSASCRIPT), Linux through fuzzel
# (PIV_FUZZEL) on a live Wayland socket. It prints only what was typed.
cat >"$work/osascript" <<EOF
#!/bin/sh
echo "osascript \$*" >>"$log"
cat "$state/answer"
EOF
cat >"$work/fuzzel" <<EOF
#!/bin/sh
echo "fuzzel WAYLAND_DISPLAY=\$WAYLAND_DISPLAY \$*" >>"$log"
cat "$state/answer"
EOF
chmod +x "$work/osascript" "$work/fuzzel"
reset
out=$(PIV_PLATFORM=darwin PIV_OSASCRIPT=$work/osascript bash "$dialog") || fail "darwin dialog failed"
[ "$out" = 12345678 ] || fail "darwin dialog returned '$out'"
grep -q "with hidden answer" "$log" || fail "darwin dialog echoes the PIN"

mkdir "$work/run"
python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$work/run/wayland-1"
reset
out=$(PIV_PLATFORM=linux PIV_FUZZEL=$work/fuzzel XDG_RUNTIME_DIR=$work/run WAYLAND_DISPLAY=stale-0 bash "$dialog") ||
  fail "linux dialog failed"
[ "$out" = 12345678 ] || fail "linux dialog returned '$out'"
grep -q "fuzzel WAYLAND_DISPLAY=wayland-1 .*--password" "$log" || fail "linux dialog: wrong socket or echoed PIN: $(cat "$log")"

rm "$work/run/wayland-1"
if PIV_PLATFORM=linux PIV_FUZZEL=$work/fuzzel XDG_RUNTIME_DIR=$work/run bash "$dialog" </dev/null >/dev/null 2>&1; then
  fail "linux dialog succeeded with no compositor and no tty"
fi

echo "piv-ensure ok"
