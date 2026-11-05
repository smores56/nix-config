# shellcheck shell=bash
# Linux half of vault.sh: FUSE via cryptomator-cli's own mounter.
is_mounted() { mountpoint -q "$1"; }
# shellcheck disable=SC2329 # called from cleanup, which only the traps invoke
unmount() { fusermount3 -u "$1" 2>/dev/null; }
# shellcheck disable=SC2329 # called from cleanup, which only the traps invoke
unmount_detach() { fusermount3 -uz "$1" 2>/dev/null; }
