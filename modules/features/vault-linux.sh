# shellcheck shell=bash
# Linux half of vault.sh: bindfs mounts a FUSE tree, so mountpoint(1) and umount(1) are enough.
is_mounted() { mountpoint -q "$1"; }
# shellcheck disable=SC2329 # called from cleanup, which only the traps invoke
unmount() { umount "$1" 2>/dev/null; }
# shellcheck disable=SC2329 # called from cleanup, which only the traps invoke
unmount_detach() { umount -l "$1" 2>/dev/null; }
home_of() { getent passwd "$1" | cut -d: -f6; }
group_of() { id -gn "$1"; }
store_owner() { echo vault; }
store_group() { echo vault; }
run_as() {
  local user=$1
  shift
  sudo -u "$user" -H env HOME="$(home_of "$user")" USER="$user" LOGNAME="$user" "$@"
}
