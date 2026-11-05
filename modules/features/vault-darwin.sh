# shellcheck shell=bash
# macOS half of vault.sh: fuse-t serves the mount over NFS, so it appears in `mount` under its
# resolved path and unmounts with umount.
is_mounted() {
  local real
  real=$(cd "$1" 2>/dev/null && pwd -P) || return 1
  grep -qF " on $real (" <<<"$(mount)"
}
# shellcheck disable=SC2329 # called from cleanup, which only the traps invoke
unmount() { umount "$1" 2>/dev/null; }
# shellcheck disable=SC2329 # called from cleanup, which only the traps invoke
unmount_detach() { diskutil unmount force "$1" >/dev/null 2>&1; }
