#!/usr/bin/env bash
# The Linux session askpass answers nothing: a presence request is announced
# and fails, every other prompt (PIN, passphrase, host key) fails with no output.
# Usage: ssh_askpass.sh <ssh-askpass>
set -euo pipefail

askpass=$1
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
cat >"$work/bin/notify-send" <<EOF2
#!/bin/sh
echo "notify \$*" >>"$work/log"
EOF2
chmod +x "$work/bin/notify-send"
export SSH_ASKPASS_NOTIFY=$work/bin/notify-send

fail() {
  echo "FAIL $*" >&2
  exit 1
}

for prompt in \
  "Enter PIN for 'smores k1 ssh': " \
  "Enter passphrase for PKCS#11: " \
  "Enter PIN for ECDSA-SK key: " \
  "Are you sure you want to continue connecting (yes/no/[fingerprint])? " \
  "Confirm user presence for key ED25519-SK SHA256:abc"; do
  if out=$("$askpass" "$prompt" 2>/dev/null); then fail "answered '$prompt'"; fi
  [ -z "$out" ] || fail "printed '$out' for '$prompt'"
done
grep -q "notify .*Confirm user presence" "$work/log" || fail "presence request not announced"
[ "$(wc -l <"$work/log")" = 1 ] || fail "notified for a non-presence prompt"
echo "ssh-askpass ok"
