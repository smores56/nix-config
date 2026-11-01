#!/usr/bin/env bash
# One place that turns "the PIN is not cached" into "the PIN is cached and
# currently valid". Prompting, the retry guard, and the cache format live here
# so ssh-pin-askpass (agent-driven, no tty), yk-ensure (PIV provider), and
# yk-login --tty (recovery) cannot drift apart.
#
# The cache is paired with the card it was verified against and that card's
# retry counter at that moment. A different serial later means another token is
# plugged in; a different counter means an attempt was spent since then or the
# card was reset/re-enrolled. Either way the PIN may no longer be valid, so the
# cache is discarded instead of replayed: ssh-agent asks at most once per
# signature, so a replay would burn a retry silently. Serial-less tokens record
# "-" and keep only the counter guard.
#
# Test seams: FIDO2_YKMAN, FIDO2_FUZZEL, FIDO2_NOTIFY override the binaries,
# and YK_ENSURE_NO_PROMPT=1 forbids a dialog for unattended callers.
set -euo pipefail

runtime="${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR is not set}"
pin_dir="$runtime/fido2"
pin_file="$pin_dir/pin"
state_file="$pin_dir/pin-state"

ykman_bin="${FIDO2_YKMAN:-ykman}"
fuzzel_bin="${FIDO2_FUZZEL:-fuzzel}"
notify_bin="${FIDO2_NOTIFY:-notify-send}"

mode=fuzzel
quiet=0
for arg in "$@"; do
  case "$arg" in
    --tty) mode="tty" ;;
    --quiet) quiet=1 ;;
    *)
      echo "fido2-ensure-pin: unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

note() {
  [ "$quiet" = 1 ] && return 0
  [ -n "$notify_bin" ] || return 0
  # Bounded and silent on stdout: this runs under the lock, and a wedged
  # session bus must not block the next signature.
  timeout 5 "$notify_bin" -a fido2 "YubiKey" "$*" >/dev/null 2>&1 || true
}

die() {
  echo "fido2-ensure-pin: $*" >&2
  exit 1
}

device_retries() {
  "$ykman_bin" fido info 2>/dev/null |
    sed -n 's/^PIN:[[:space:]]*\([0-9][0-9]*\) attempt(s) remaining.*/\1/p'
}

# Enumeration, not the applet: cheap, and stable across a reset of the FIDO2
# application. Several plugged tokens compare as a set, so a changed set is a
# changed device.
device_serial() {
  "$ykman_bin" list --serials 2>/dev/null | paste -sd, -
}

# "<serial>:<retries>" is the whole freshness key for the cache.
device_state() {
  local serial retries
  serial=$(device_serial) || serial=""
  [ -n "$serial" ] || serial="-"
  retries=$(device_retries) || return 1
  [ -n "$retries" ] || return 1
  printf '%s:%s' "$serial" "$retries"
}

# fresh: verified, and the same card's counter has not moved since.
# unknown: the card cannot be interrogated right now (busy or unplugged). A
#   verified cache is still the best answer, and a signature that cannot reach
#   the card fails on its own without spending a retry, so this is not an error.
# stale: missing, malformed, or a counter that moved.
cache_state() {
  if [ ! -s "$pin_file" ] || [ ! -r "$state_file" ]; then
    printf stale
    return
  fi
  if [[ ! $(cat "$pin_file") =~ ^[0-9]{8}$ ]]; then
    printf stale
    return
  fi
  local current
  if ! current=$(device_state); then
    printf unknown
    return
  fi
  if [ "$current" = "$(cat "$state_file")" ]; then
    printf fresh
  else
    printf stale
  fi
}

# The askpass inherits the agent's start-time environment, which may name a
# socket from an earlier session or predate the compositor entirely, so trust
# a live path and otherwise take the newest live socket in the runtime dir.
wayland_socket() {
  if [ -n "${WAYLAND_DISPLAY:-}" ]; then
    case "$WAYLAND_DISPLAY" in
      /*)
        if [ -S "$WAYLAND_DISPLAY" ]; then
          printf '%s' "$WAYLAND_DISPLAY"
          return 0
        fi
        ;;
      *)
        if [ -S "$runtime/$WAYLAND_DISPLAY" ]; then
          printf '%s' "$WAYLAND_DISPLAY"
          return 0
        fi
        ;;
    esac
  fi
  newest=""
  for s in "$runtime"/wayland-[0-9]*; do
    [ -S "$s" ] || continue
    if [ -z "$newest" ] || [ "$s" -nt "$newest" ]; then
      newest=$s
    fi
  done
  [ -n "$newest" ] || return 1
  printf '%s' "${newest##*/}"
}

# Exactly one dialog per call: a cancelled prompt is a failure, not a reason to
# try another display. The trailing space keeps the masked input off the prompt
# text, matching fuzzel's own "> " default.
prompt_pin() {
  if [ "$mode" = tty ]; then
    [ -t 0 ] || return 1
    local pin
    read -rsp 'YubiKey PIN ' pin || return 1
    echo >&2
    printf '%s' "$pin"
    return 0
  fi
  wl=$(wayland_socket) || return 1
  WAYLAND_DISPLAY=$wl "$fuzzel_bin" --dmenu --prompt-only="YubiKey PIN " \
    --password='*' --namespace=pin --cache=/dev/null 2>/dev/null
}

case "$(cache_state)" in
  fresh | unknown) exit 0 ;;
esac

if [ "${YK_ENSURE_NO_PROMPT:-0}" = 1 ]; then
  die "no cached PIN and prompting is disabled; run yk-login in a terminal"
fi

exec 9>"$runtime/fido2-ensure.lock"
# Bounded: an abandoned dialog must not block every later signature forever.
flock -w 60 9 || die "another PIN prompt is still open"

# Parallel signers queue here; the first prompt fills the cache for the rest.
case "$(cache_state)" in
  fresh | unknown) exit 0 ;;
esac

info=$("$ykman_bin" fido info 2>/dev/null) ||
  die "cannot read the YubiKey; is it plugged in?"
case "$info" in
  *"PIN: Blocked"*) die "the FIDO2 PIN is blocked; reset it with 'ykman fido access reset'" ;;
  *"PIN: Not set"*) die "the FIDO2 PIN is not set" ;;
esac
retries=$(printf '%s\n' "$info" |
  sed -n 's/^PIN:[[:space:]]*\([0-9][0-9]*\) attempt(s) remaining.*/\1/p')
[ -n "$retries" ] || die "the FIDO2 retry count is unavailable"
if [ "$retries" -lt 4 ]; then
  note "Fewer than 4 FIDO2 retries remain; refusing to send the PIN."
  die "only $retries FIDO2 retries remain; refusing to send the PIN. Verify it by hand with 'ykman fido access verify-pin'"
fi

# Anything that reached this point is a cache the freshness check rejected.
rm -f "$pin_file" "$state_file"

# fd 9 stays out of the dialog's process tree: a running fuzzel must not hold
# the lock after this script is gone.
if ! pin=$(prompt_pin 9>&-); then
  note "Could not read the YubiKey PIN."
  die "no cached PIN: the prompt was cancelled or no display is available (run yk-login in a terminal)"
fi

if [[ ! $pin =~ ^[0-9]{8}$ ]]; then
  note "Enter the 8-digit YubiKey PIN."
  die "the PIN must be exactly 8 digits"
fi

if ! "$ykman_bin" fido access verify-pin --pin "$pin" >/dev/null 2>&1; then
  left=$(device_retries || true)
  note "The YubiKey rejected that PIN."
  die "the YubiKey rejected the PIN${left:+ ($left retries remaining)}"
fi

# Only a verified PIN is written. The device resets its retry counter on a
# successful verification, so the snapshot is taken after the verify; taking
# the pre-verify value would make the next call re-prompt for nothing.
state=$(device_state || true)

umask 077
mkdir -p "$pin_dir"
printf '%s' "$pin" >"$pin_file"
chmod 600 "$pin_file"
# Without a fresh snapshot the next call re-prompts instead of trusting it.
if [ -n "$state" ]; then
  printf '%s' "$state" >"$state_file"
  chmod 600 "$state_file"
fi
