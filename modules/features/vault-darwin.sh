# shellcheck shell=bash
# macOS half of vault.sh: fuse-t serves the mount over a loopback NFS server, so it appears in
# `mount` under its resolved path and unmounts with umount (or diskutil when a child holds it).
is_mounted() {
  local real
  real=$(cd "$1" 2>/dev/null && pwd -P) || return 1
  grep -qF " on $real (" <<<"$(mount)"
}
# shellcheck disable=SC2329 # called from cleanup, which only the traps invoke
unmount() { umount "$1" 2>/dev/null; }
# shellcheck disable=SC2329 # called from cleanup, which only the traps invoke
unmount_detach() { diskutil unmount force "$1" >/dev/null 2>&1; }
home_of() { dscl . -read "/Users/$1" NFSHomeDirectory | awk '{print $2}'; }
group_of() { id -gn "$1"; }
run_as() {
  local user=$1
  shift
  /usr/bin/sudo -u "$user" -- "$@"
}
