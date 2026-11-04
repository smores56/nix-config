# Masked macOS dialog for piv-ensure. Answers only ssh-add's PKCS#11 prompt,
# and only with a 6-8 character PIN: an empty or timed-out answer would still
# be sent to the card and spend a retry.
set -euo pipefail

[ "${1:-}" = "Enter passphrase for PKCS#11: " ] || exit 1

pin=$("${PIV_OSASCRIPT:-/usr/bin/osascript}" \
  -e 'text returned of (display dialog "YubiKey PIV PIN for smortress" default answer "" with hidden answer with title "SSH" giving up after 120)') ||
  exit 1
[ "${#pin}" -ge 6 ] && [ "${#pin}" -le 8 ] || exit 1
printf '%s\n' "$pin"
