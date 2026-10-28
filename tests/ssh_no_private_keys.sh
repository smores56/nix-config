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
rm "$work/.ssh/nested/id_nested"

# Only the explicit work-host exception allows the root gcloud key.
ssh-keygen -q -t ed25519 -N "" -f "$work/.ssh/google_compute_engine"
"$tool" "$work/.ssh" >/dev/null 2>&1 && fail "gcloud key accepted without exception"
"$tool" "$work/.ssh" --allow-gcloud-key >/dev/null 2>&1 || fail "gcloud key rejected with exception"
cp "$work/linked" "$work/.ssh/id_other"
"$tool" "$work/.ssh" --allow-gcloud-key >/dev/null 2>&1 && fail "other private key accepted with exception"
rm "$work/.ssh/id_other"

# The exception must not accept a symlink or a similarly named nested key.
rm "$work/.ssh/google_compute_engine"
ln -s "$work/linked" "$work/.ssh/google_compute_engine"
"$tool" "$work/.ssh" --allow-gcloud-key >/dev/null 2>&1 && fail "gcloud symlink accepted"
rm "$work/.ssh/google_compute_engine"
cp "$work/linked" "$work/.ssh/nested/google_compute_engine"
"$tool" "$work/.ssh" --allow-gcloud-key >/dev/null 2>&1 && fail "nested gcloud key accepted"

# A missing directory is fine (fresh host).
"$tool" "$work/absent" >/dev/null 2>&1 || fail "missing directory was rejected"

echo "ssh-no-private-keys ok"
