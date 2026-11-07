#!/usr/bin/env bash
# Open the vault for one foreground session. Must be started as root through `sudo vault`.
#
# The store is owned by the `vault` user and the human's uid has no access to it at rest, so this
# mount is the only way in. bindfs maps the vault user to the caller, so inside ~/Vault everything
# looks owned by the human and editors, file managers and previewers behave normally.
#
# No argument: hold the mount until Ctrl-C. With a command: run it in ~/Vault as the caller and
# unmount when it exits. Either way the trap unmounts, so the window is exactly the foreground
# process.
#
# Usage: sudo vault [command [args...]]

@PLATFORM@

store=@STORE@

if [ "$(id -u)" -ne 0 ]; then
  echo "vault: run this as 'sudo vault'" >&2
  exit 1
fi
caller=${SUDO_USER:-}
if [ -z "$caller" ] || [ "$caller" = root ]; then
  echo "vault: start it as 'sudo vault' from your own session, not as root" >&2
  exit 1
fi
if [ ! -d "$store" ]; then
  echo "vault: $store is missing; run the migration first" >&2
  exit 1
fi

mountpoint="$(home_of "$caller")/Vault"
if [ -z "${mountpoint%/Vault}" ]; then
  echo "vault: could not resolve $caller's home directory" >&2
  exit 1
fi
if is_mounted "$mountpoint"; then
  # A FUSE mount whose server died still answers `mountpoint`; detach it rather than refusing
  # until the next reboot.
  if ! stat "$mountpoint" >/dev/null 2>&1; then
    unmount_detach "$mountpoint" || true
  fi
  if is_mounted "$mountpoint"; then
    echo "vault: $mountpoint is already open" >&2
    exit 1
  fi
fi

mkdir -p "$mountpoint"
chown "$caller" "$mountpoint"

mounter=
# shellcheck disable=SC2329 # invoked by the traps
cleanup() {
  # Run once: the INT/TERM trap ends in `exit`, which would fire the EXIT trap again.
  trap - EXIT INT TERM
  # A child the command left behind keeps a file open, so a plain unmount fails with EBUSY: detach
  # the tree instead of leaving a stale mount owned by a dead session.
  if ! unmount "$mountpoint"; then
    unmount_detach "$mountpoint" || true
  fi
  if [ -n "$mounter" ]; then
    for _ in $(seq 1 20); do
      kill -0 "$mounter" 2>/dev/null || break
      sleep 0.25
    done
    kill "$mounter" 2>/dev/null || true
    wait "$mounter" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

# The store is 0700 for the vault user; mapping that user to the caller is what makes the tree
# usable for the session without ever handing the human's uid the real permissions.
bindfs --foreground -u "$caller" -g "$(group_of "$caller")" \
  --create-for-user="$(store_owner)" --create-for-group="$(store_group)" \
  "$store" "$mountpoint" &
mounter=$!

for _ in $(seq 1 60); do
  is_mounted "$mountpoint" && break
  if ! jobs -pr | grep -qx "$mounter"; then
    echo "vault: bindfs exited before mounting" >&2
    exit 1
  fi
  sleep 0.25
done
if ! is_mounted "$mountpoint"; then
  echo "vault: no mount appeared within 15s" >&2
  exit 1
fi

if [ "$#" -eq 0 ]; then
  echo "vault open at $mountpoint; Ctrl-C to close."
  wait "$mounter" || true
else
  ( cd "$mountpoint" && run_as "$caller" "$@" )
fi
