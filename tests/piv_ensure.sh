#!/usr/bin/env bash
# The macOS PIV pre-connect step: a no-op on a warm agent; on a cold one it
# loads the provider once, through a forced askpass with no stdin, only when
# the PIN retry budget allows; it never retries a failed load or opens a
# dialog for a no-prompt caller. The GUI askpass answers only ssh-add's
# PKCS#11 prompt and only with a plausible PIN.
# Usage: piv_ensure.sh <piv-ensure.sh> <piv-askpass.sh>
set -euo pipefail

ensure=$1
gui=$2
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() {
  echo "FAIL $*" >&2
  exit 1
}

mkdir "$work/bin"
log=$work/log
state=$work/state

# ssh-add fake: -T succeeds once `warm` exists; -s records how it was called
# and warms the agent unless `load-fails`/`load-cold` is set.
cat >"$work/bin/ssh-add" <<EOF
#!/usr/bin/env bash
case \$1 in
  -T) [ -e "$state/warm" ] ;;
  -e) echo "-e \$2" >>"$log"; exit 1 ;;
  -s)
    stdin=tty; [ -t 0 ] || stdin=notty
    read -r -t 1 piped || piped=
    echo "-s \$2 askpass=\$SSH_ASKPASS require=\$SSH_ASKPASS_REQUIRE sock=\$SSH_AUTH_SOCK stdin=\$stdin piped=\$piped" >>"$log"
    [ -e "$state/load-fails" ] && exit 1
    [ -e "$state/load-cold" ] || touch "$state/warm"
    ;;
  *) exit 2 ;;
esac
EOF
cat >"$work/bin/ykman" <<EOF
#!/usr/bin/env bash
echo ykman >>"$log"
[ -e "$state/no-card" ] && { echo "ERROR: No YubiKey detected" >&2; exit 2; }
printf 'PIV version:              5.7.1\nPIN tries remaining:      %s/3\n' "\$(cat "$state/tries")"
EOF
chmod +x "$work/bin/ssh-add" "$work/bin/ykman"
export PATH="$work/bin:$PATH"

sock=$work/piv-agent.sock
provider=/nix/store/x-opensc/lib/opensc-pkcs11.so

# reset [files...]: fresh state with 3 tries and the given flags set.
reset() {
  rm -rf "$state" "$log"
  mkdir "$state"
  : >"$log"
  echo 3 >"$state/tries"
  for f in "$@"; do touch "$state/$f"; done
}
run() {
  echo "PIN-FROM-PIPE" | env -u SSH_ASKPASS -u YK_ENSURE_NO_PROMPT "$@" \
    bash "$ensure" "$sock" "$provider" /gui/askpass "$work/k1.pub" "$work/k2.pub"
}
loads() { grep -c '^-s ' "$log" || true; }

reset warm
run || fail "warm agent failed"
[ ! -s "$log" ] || fail "warm agent touched the card: $(cat "$log")"

reset
run || fail "cold agent did not load"
[ "$(loads)" = 1 ] || fail "cold agent loaded $(loads) times"
grep -q "^-e $provider" "$log" || fail "stale provider not removed first"
grep -q "^-s $provider askpass=/gui/askpass require=force sock=$sock stdin=notty piped=$" "$log" ||
  fail "load not forced through the GUI askpass with empty stdin: $(cat "$log")"

reset
run SSH_ASKPASS=/caller/askpass || fail "caller askpass did not load"
grep -q "askpass=/caller/askpass require=force" "$log" || fail "caller askpass ignored: $(cat "$log")"

reset
if run YK_ENSURE_NO_PROMPT=1 2>/dev/null; then fail "no-prompt caller loaded a cold agent"; fi
[ "$(loads)" = 0 ] || fail "no-prompt caller reached ssh-add -s"

reset
run YK_ENSURE_NO_PROMPT=1 SSH_ASKPASS=/caller/askpass || fail "no-prompt caller with its own askpass failed"

reset
echo 1 >"$state/tries"
if run 2>/dev/null; then fail "loaded with one PIN try left"; fi
[ "$(loads)" = 0 ] || fail "low retry budget still reached ssh-add -s"

reset
echo garbage >"$state/tries"
if run 2>/dev/null; then fail "loaded with an unreadable retry count"; fi
[ "$(loads)" = 0 ] || fail "unreadable retry count still reached ssh-add -s"

reset no-card
out=$(run 2>&1) && fail "loaded with no readable card"
[[ $out == *"retry count"* ]] || fail "ykman failure lost its hint: '$out'"
[ "$(loads)" = 0 ] || fail "ykman failure still reached ssh-add -s"

reset load-fails
if run 2>/dev/null; then fail "failed load reported success"; fi
[ "$(loads)" = 1 ] || fail "failed load was retried ($(loads) loads)"

reset load-cold
if run 2>/dev/null; then fail "load that left the agent unusable reported success"; fi

# GUI askpass: osascript is faked through PIV_OSASCRIPT.
cat >"$work/osascript" <<EOF
#!/bin/sh
cat "$state/answer"
EOF
chmod +x "$work/osascript"
export PIV_OSASCRIPT=$work/osascript
reset
echo 12345678 >"$state/answer"
out=$(bash "$gui" "Enter passphrase for PKCS#11: ") || fail "GUI askpass rejected a valid PIN"
[ "$out" = 12345678 ] || fail "GUI askpass returned '$out'"
for prompt in \
  "Enter PIN for 'smores k1 ssh': " \
  "Are you sure you want to continue connecting (yes/no/[fingerprint])? "; do
  if out=$(bash "$gui" "$prompt" 2>/dev/null); then fail "GUI askpass answered '$prompt'"; fi
  [ -z "$out" ] || fail "GUI askpass leaked '$out'"
done
for answer in "" 12345 123456789; do
  echo "$answer" >"$state/answer"
  if bash "$gui" "Enter passphrase for PKCS#11: " >/dev/null 2>&1; then
    fail "GUI askpass accepted '$answer'"
  fi
done

echo "piv-ensure ok"
