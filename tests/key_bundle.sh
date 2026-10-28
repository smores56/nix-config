#!/usr/bin/env bash
# Round-trip a FIDO2 handle bundle. A normal ed25519 key stands in for the
# hardware-backed handle: the bundle code only copies and fingerprints files,
# so it exercises the same path without a YubiKey. --pubkeys supplies the
# committed public-half map the real build embeds.
set -euo pipefail

backup=${1:?usage: key_bundle.sh <key-backup> <key-restore>}
restore=${2:?usage: key_bundle.sh <key-backup> <key-restore>}

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

fail() {
  echo "key_bundle: $*" >&2
  exit 1
}

mode() {
  ls -ld "$1" | cut -c1-10
}

src="$root/src"
mkdir -p "$src/.config/ssh-sk/k1" "$src/dev"
ssh-keygen -q -t ed25519 -N "" -C "test k1 sudo" -f "$src/.config/ssh-sk/k1/sudo"
ssh-keygen -q -t ed25519 -N "" -C "not the same key" -f "$root/wrong"
printf '#!/bin/sh\necho hi\n' >"$src/dev/setup-yubikey.sh"
chmod 700 "$src/dev/setup-yubikey.sh"

pubkeys="$root/pubkeys"
printf 'k1/sudo\t%s\n' "$(awk '{print $1" "$2}' "$src/.config/ssh-sk/k1/sudo.pub")" >"$pubkeys"
wrongkeys="$root/wrongkeys"
printf 'k1/sudo\t%s\n' "$(awk '{print $1" "$2}' "$root/wrong.pub")" >"$wrongkeys"

run_backup() {
  env -u XDG_STATE_HOME HOME="$src" "$backup" --pubkeys "$pubkeys" "$@"
}

run_restore() {
  local home="$1"
  shift
  env -u XDG_STATE_HOME HOME="$home" "$restore" --pubkeys "$pubkeys" "$@"
}

run_backup >/dev/null
archive=$(find "$src/.local/state/key-backup" -name '*.tar.gz' -print -quit)
[ -n "$archive" ] || fail "key-backup wrote no archive"
[ -f "$archive.sha256" ] || fail "key-backup wrote no checksum"
[ "$(mode "$archive")" = "-rw-------" ] || fail "archive is not 0600"
[ "$(mode "$archive.sha256")" = "-rw-------" ] || fail "checksum is not 0600"

contents="$(tar -tzf "$archive")"
for forbidden in keys.age "root/"; do
  case "$contents" in
    *"$forbidden"*) fail "bundle contains forbidden $forbidden" ;;
  esac
done
for wanted in home/.config/ssh-sk/k1/sudo home/dev/setup-yubikey.sh; do
  grep -qF "$wanted" <<<"$contents" || fail "bundle is missing $wanted"
done

dst="$root/dst"
mkdir -p "$dst"
run_restore "$dst" "$archive" >/dev/null
cmp "$src/.config/ssh-sk/k1/sudo" "$dst/.config/ssh-sk/k1/sudo" \
  || fail "restored handle differs"
[ "$(mode "$dst/.config/ssh-sk/k1/sudo")" = "-rw-------" ] || fail "handle is not 0600"
[ "$(mode "$dst/dev/setup-yubikey.sh")" = "-rw-------" ] || fail "script is not 0600"

# A second restore must refuse to clobber an existing handle.
if run_restore "$dst" "$archive" >/dev/null 2>&1; then
  fail "overwrote a handle without --force"
fi
run_restore "$dst" "$archive" --force >/dev/null

# A handle must match the committed public half.
dst_wrong="$root/dst-wrong"
mkdir -p "$dst_wrong"
if env -u XDG_STATE_HOME HOME="$dst_wrong" "$restore" --pubkeys "$wrongkeys" "$archive" >/dev/null 2>&1; then
  fail "accepted a handle that does not match the public half"
fi

# The documented flow renames the download; the checksum must still validate.
moved="$root/moved"
mkdir -p "$moved"
cp "$archive" "$moved/bundle.tar.gz"
cp "$archive.sha256" "$moved/bundle.tar.gz.sha256"
dst_moved="$root/dst-moved"
mkdir -p "$dst_moved"
run_restore "$dst_moved" "$moved/bundle.tar.gz" >/dev/null

# Without the checksum restore refuses unless explicitly told not to verify.
noverify="$root/noverify"
mkdir -p "$noverify"
cp "$archive" "$noverify/bundle.tar.gz"
dst_noverify="$root/dst-noverify"
mkdir -p "$dst_noverify"
if run_restore "$dst_noverify" "$noverify/bundle.tar.gz" >/dev/null 2>&1; then
  fail "accepted a bundle with no checksum"
fi
run_restore "$dst_noverify" "$noverify/bundle.tar.gz" --no-verify >/dev/null

# A modified archive must fail the checksum before extraction.
cp "$archive" "$root/bad.tar.gz"
printf 'x' >>"$root/bad.tar.gz"
sha256sum "$archive" | awk '{print $1}' >"$root/bad.tar.gz.sha256"
if run_restore "$root/dst-bad" "$root/bad.tar.gz" >/dev/null 2>&1; then
  fail "accepted a tampered archive"
fi

# A partial set fails unless explicitly allowed.
partialkeys="$root/partialkeys"
cp "$pubkeys" "$partialkeys"
printf 'k1/signing\t%s\n' "$(awk '{print $1" "$2}' "$src/.config/ssh-sk/k1/sudo.pub")" >>"$partialkeys"
if env -u XDG_STATE_HOME HOME="$src" "$backup" --pubkeys "$partialkeys" >/dev/null 2>&1; then
  fail "archived a partial set without --allow-incomplete"
fi
env -u XDG_STATE_HOME HOME="$src" "$backup" --pubkeys "$partialkeys" --allow-incomplete >/dev/null
