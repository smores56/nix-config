#!/usr/bin/env bash
# The macOS PIV askpass must answer only the PKCS#11 PIN prompt and fail
# closed (with no PIN on stdout) for host-key and presence prompts.
# Usage: wallpapers_askpass.sh <wallpapers-askpass>
set -euo pipefail

askpass=$1
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() {
  echo "FAIL $*" >&2
  exit 1
}

cat >"$work/security" <<'EOF'
#!/bin/sh
printf '123456\n'
EOF
chmod +x "$work/security"
export WALLPAPERS_SECURITY=$work/security

out=$("$askpass" "Enter PIN for 'smores k2 ssh': ")
[ "$out" = "123456" ] || fail "PIN prompt got '$out'"

for prompt in \
  "Are you sure you want to continue connecting (yes/no/[fingerprint])? " \
  "Confirm user presence for key ED25519-SK SHA256:abc"; do
  if out=$("$askpass" "$prompt" 2>/dev/null); then
    fail "answered '$prompt' with '$out'"
  fi
  [ -z "${out:-}" ] || fail "'$prompt' leaked '$out'"
done

cat >"$work/security-fail" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$work/security-fail"
if WALLPAPERS_SECURITY=$work/security-fail "$askpass" "Enter PIN for 'x': " >/dev/null 2>&1; then
  fail "a failing Keychain read still succeeded"
fi

echo "wallpapers-askpass ok"
