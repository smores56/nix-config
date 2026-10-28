#!/usr/bin/env bash
# ~/.ssh must hold only public material; identities live in the agent/key.
# Usage: ssh_no_private_keys.sh <ssh-no-private-keys>
set -euo pipefail

tool=$1
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/.ssh"

fail() {
  echo "FAIL $*" >&2
  exit 1
}

# A private key, its public half, and a non-key file: the private key must be
# rejected even when the public/other files are present.
ssh-keygen -q -t ed25519 -N "" -f "$work/.ssh/id_private"
cp "$work/.ssh/id_private.pub" "$work/.ssh/id_public.pub"
printf 'not a key\n' >"$work/.ssh/known_hosts"
"$tool" "$work/.ssh" >/dev/null 2>&1 && fail "private key was accepted"

# Removing the private key must make the same directory pass.
rm "$work/.ssh/id_private"
"$tool" "$work/.ssh" >/dev/null 2>&1 || fail "public-only directory was rejected"

# A symlink to a private key is still a private key.
ssh-keygen -q -t ed25519 -N "" -f "$work/linked"
ln -s "$work/linked" "$work/.ssh/id_linked"
"$tool" "$work/.ssh" >/dev/null 2>&1 && fail "symlinked private key was accepted"
rm "$work/.ssh/id_linked"

# Nested private keys count too.
mkdir "$work/.ssh/nested"
ssh-keygen -q -t ed25519 -N "" -f "$work/.ssh/nested/id_nested"
"$tool" "$work/.ssh" >/dev/null 2>&1 && fail "nested private key was accepted"

# A missing directory is fine (fresh host).
"$tool" "$work/absent" >/dev/null 2>&1 || fail "missing directory was rejected"

echo "ssh-no-private-keys ok"
