#!/usr/bin/env bash
# The Linux session askpass answers a password prompt through the masked PIV
# dialog and fails closed on everything else: a host-key question (no hint), an
# agent permission question (hint confirm), and a touch request (hint none) all
# exit non-zero with no output, the last one after a notification.
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
cat >"$work/bin/osascript" <<EOF2
#!/bin/sh
echo "osascript \$*" >>"$work/log"
cat "$work/secret"
EOF2
chmod +x "$work/bin/notify-send" "$work/bin/osascript"
export SSH_ASKPASS_NOTIFY=$work/bin/notify-send
: >"$work/log"
printf 'smores-password\n' >"$work/secret"

fail() {
  echo "FAIL $*" >&2
  exit 1
}

# sshconnect.c confirm(): no SSH_ASKPASS_PROMPT at all.
for prompt in \
  "The authenticity of host 'ssh.sammohr.dev (203.0.113.7)' can't be established.
ED25519 key fingerprint is SHA256:abc.
Are you sure you want to continue connecting (yes/no/[fingerprint])? " \
  "Please type 'yes', 'no' or the fingerprint: "; do
  if out=$(env -u SSH_ASKPASS_PROMPT "$askpass" "$prompt" 2>/dev/null); then fail "answered '$prompt'"; fi
  [ -z "$out" ] || fail "printed '$out' for '$prompt'"
done

# ssh-agent ask_permission(): hint confirm.
if out=$(SSH_ASKPASS_PROMPT=confirm "$askpass" "Allow use of key smores k1?
Key fingerprint SHA256:abc." 2>/dev/null); then
  fail "answered the agent permission question"
fi
[ -z "$out" ] || fail "printed '$out' for the agent permission question"

# ssh-agent notify_start(): hint none, announced and never answered.
if out=$(SSH_ASKPASS_PROMPT=none "$askpass" "Confirm user presence for key ED25519-SK SHA256:abc" 2>/dev/null); then
  fail "answered a touch request"
fi
[ -z "$out" ] || fail "printed '$out' for a touch request"
grep -q "notify .*Confirm user presence" "$work/log" || fail "presence request not announced"
[ "$(grep -c '^notify' "$work/log" || true)" = 1 ] || fail "notified for a non-presence prompt"

# A PIN prompt belongs to piv-ensure and never reaches the dialog.
if out=$(env -u SSH_ASKPASS_PROMPT "$askpass" "Enter PIN for 'smores k1 ssh': " 2>/dev/null); then
  fail "answered a PKCS#11 PIN prompt"
fi
[ -z "$out" ] || fail "printed '$out' for a PKCS#11 PIN prompt"

# The password prompt (no hint) opens the masked dialog and prints the typed secret.
out=$(env -u SSH_ASKPASS_PROMPT PIV_PLATFORM=darwin PIV_OSASCRIPT=$work/bin/osascript \
  "$askpass" "smores@ssh.sammohr.dev's password: ")
[ "$out" = smores-password ] || fail "password prompt returned '$out'"
grep -q "with hidden answer" "$work/log" || fail "password dialog is not masked"
[ "$(grep -c '^notify' "$work/log" || true)" = 1 ] || fail "password prompt notified"

echo "ssh-askpass ok"
