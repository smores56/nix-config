#!/usr/bin/env bash
# Pre-connect step for the PIV agent on both laptops. The PIN is typed once per
# login session: it is cached only after the card accepted it, and replayed
# only for the same card with an unspent counter, so a replay cannot burn a try.
# Any ykman call resets OpenSC's verified state, so the card is read only
# before a load, never after.
# Usage: piv-ensure <agent-socket> <pkcs11-provider> <cache-dir> <dialog> <cache-askpass> <pub>...
set -euo pipefail

sock=$1
provider=$2
cache=$3
dialog=$4
askpass=$5
shift 5

die() {
  echo "piv-ensure: $*" >&2
  exit 1
}

# A listed key is not proof: after unplug or sleep the agent still lists it
# but cannot sign. -T signs and verifies.
healthy() {
  local pub
  for pub in "$@"; do
    SSH_AUTH_SOCK=$sock timeout 15 ssh-add -T "$pub" </dev/null >/dev/null 2>&1 && return 0
  done
  return 1
}

healthy "$@" && exit 0
[ -S "$sock" ] || die "the PIV agent is not running ($sock)"

umask 077
mkdir -p "$cache"
[ -d "$cache" ] && [ ! -L "$cache" ] && [ -O "$cache" ] || die "$cache is not a private directory"
chmod 700 "$cache"
pin_file=$cache/pin
card_file=$cache/card

# One unlock at a time; a parallel caller waits and finds the agent warm.
exec 9>"$cache/lock"
flock -w 120 9 || die "another unlock is still running"
healthy "$@" && exit 0

read -r tries max < <(timeout 10 ykman piv info </dev/null 2>/dev/null |
  sed -n 's/^PIN tries remaining:[[:space:]]*\([0-9][0-9]*\)\/\([0-9][0-9]*\).*/\1 \2/p') || true
[ -n "${tries:-}" ] && [ -n "${max:-}" ] ||
  die "cannot read the PIV PIN retry count; is exactly one YubiKey inserted?"
[ "$tries" -ge 2 ] || die "only $tries PIV PIN try left; recover the PIN before using SSH"
serial=$(timeout 10 ykman list --serials </dev/null 2>/dev/null | sort -u | paste -sd, -) || serial=
serial=${serial:--}

# ssh-add reads the PIN through the askpass from the cache file; stdin is a
# ProxyCommand's transport, so it must never be read as the PIN.
load() {
  SSH_AUTH_SOCK=$sock timeout 15 ssh-add -e "$provider" </dev/null >/dev/null 2>&1 || true
  SSH_AUTH_SOCK=$sock PIV_PIN_FILE=$pin_file SSH_ASKPASS=$askpass SSH_ASKPASS_REQUIRE=force \
    timeout 30 ssh-add -s "$provider" </dev/null >/dev/null 2>&1 && healthy "$@"
}

if [ -s "$pin_file" ] && [ ! -L "$pin_file" ] && [ "$tries" = "$max" ] && [ "$(cat "$card_file" 2>/dev/null)" = "$serial" ]; then
  load "$@" && exit 0
  rm -f "$pin_file" "$card_file"
  die "the cached PIN no longer unlocks the agent"
fi
rm -f "$pin_file" "$card_file"

[ -z "${YK_ENSURE_NO_PROMPT:-}" ] ||
  die "PIV agent is cold and no PIN is cached; run 'ssh smortress true' interactively first"

pin=$("$dialog" </dev/null 9>&-) || die "PIV unlock was cancelled or no prompt is available"
[[ $pin =~ ^[^[:space:]]{6,8}$ ]] || die "the PIV PIN must be 6-8 characters"

printf '%s' "$pin" >"$pin_file"
if ! load "$@"; then
  rm -f "$pin_file"
  die "PIV unlock failed; not retrying"
fi
printf '%s' "$serial" >"$card_file"
