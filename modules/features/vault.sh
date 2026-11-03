#!/usr/bin/env bash
# Unlock the Cryptomator vault for exactly one command, then unmount.
#
# The password is read from the terminal and handed to cryptomator-cli on
# stdin, so it never appears in argv or in the process list. Nothing stays
# mounted after the command: the trap unmounts and removes the mount point even
# when the command fails or the session is interrupted.
#
# Usage: vault <command> [args...]

if [ "$#" -eq 0 ]; then
  echo "usage: vault <command> [args...]" >&2
  echo "  e.g. vault yazi, vault zathura ./docs/book.pdf" >&2
  exit 2
fi

vault_dir=@VAULT@
if [ ! -f "$vault_dir/vault.cryptomator" ]; then
  echo "vault: $vault_dir is not a Cryptomator vault" >&2
  exit 1
fi

pass=
IFS= read -rs -p 'vault password: ' pass || {
  echo
  echo "vault: no password entered" >&2
  exit 1
}
echo

mountpoint=$(mktemp -d "${TMPDIR:-/tmp}/vault.XXXXXX")
cli=
# shellcheck disable=SC2329 # invoked by the trap on the next line
cleanup() {
  fusermount3 -u "$mountpoint" 2>/dev/null || true
  if [ -n "$cli" ]; then
    wait "$cli" 2>/dev/null || true
  fi
  rmdir "$mountpoint" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

printf '%s\n' "$pass" | cryptomator-cli unlock --password:stdin \
  --mounter=@MOUNTER@ --mountPoint="$mountpoint" "$vault_dir" &
cli=$!
pass=

for _ in $(seq 1 60); do
  mountpoint -q "$mountpoint" && break
  if ! kill -0 "$cli" 2>/dev/null; then
    echo "vault: cryptomator-cli exited before mounting (wrong password?)" >&2
    exit 1
  fi
  sleep 0.5
done
mountpoint -q "$mountpoint" || {
  echo "vault: no mount appeared within 30s" >&2
  exit 1
}

status=0
( cd "$mountpoint" && "$@" ) || status=$?
exit "$status"
