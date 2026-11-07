#!/usr/bin/env bash
# Asks for a secret once and prints it: a masked macOS dialog, fuzzel on the
# live Wayland session, or the controlling terminal when neither exists. The
# optional argument is the prompt label (default: the PIV PIN); only the Linux
# surfaces use it, so the AppleScript label stays a constant.
set -euo pipefail

label=${1-YubiKey PIN}
# ssh's password prompt already ends in ": "; keep fuzzel's own spacing clean.
label=${label%"${label##*[![:space:]]}"}

case ${PIV_PLATFORM:-$(uname -s)} in
  darwin | Darwin)
    exec "${PIV_OSASCRIPT:-/usr/bin/osascript}" \
      -e 'text returned of (display dialog "YubiKey PIV PIN" default answer "" with hidden answer with title "SSH" giving up after 120)'
    ;;
esac

# The caller's WAYLAND_DISPLAY may predate the compositor: trust a live socket, else the newest in the runtime dir.
wayland_socket() {
  local runtime=${XDG_RUNTIME_DIR:-} name=${WAYLAND_DISPLAY:-} s newest=""
  [ -n "$runtime" ] || return 1
  if [ -n "$name" ] && { [ -S "$name" ] || [ -S "$runtime/$name" ]; }; then
    printf '%s' "$name"
    return 0
  fi
  for s in "$runtime"/wayland-[0-9]*; do
    [ -S "$s" ] || continue
    if [ -z "$newest" ] || [ "$s" -nt "$newest" ]; then newest=$s; fi
  done
  [ -n "$newest" ] && printf '%s' "${newest##*/}"
}

if wl=$(wayland_socket); then
  WAYLAND_DISPLAY=$wl exec timeout 120 "${PIV_FUZZEL:-fuzzel}" --dmenu --prompt-only="$label " \
    --password='*' --namespace=pin --cache=/dev/null
fi

if { exec 3<>/dev/tty; } 2>/dev/null; then
  printf '%s ' "$label" >&3
  IFS= read -rs pin <&3 || exit 1
  printf '\n' >&3
  printf '%s\n' "$pin"
  exit 0
fi
exit 1
