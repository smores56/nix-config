#!/usr/bin/env bash
# Round-trip a FIDO2 handle bundle. A normal ed25519 key stands in for the
# hardware-backed handle: the bundle code only copies and fingerprints files,
# so it exercises the same path without a YubiKey. --pubkeys supplies the
# committed public-half map the real build embeds, and a generated ed25519 key
# stands in for /etc/ssh so the host-key backup and `--host-key` restore run
# without root.
set -euo pipefail

backup=${1:?usage: key_bundle.sh <key-backup> <key-restore>}
restore=${2:?usage: key_bundle.sh <key-backup> <key-restore>}

# The bundle hooks (--pubkeys, --target-dir, --sops-file) are gated behind this.
export KEY_BUNDLE_TEST=1

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

# key-backup now requires .sops.yaml in the working directory, so every backup
# runs from a scratch checkout.
checkout="$root/checkout"
mkdir -p "$checkout"
: >"$checkout/flake.nix"
printf 'keys:\n' >"$checkout/.sops.yaml"

run_backup() {
  ( cd "$checkout" && env -u XDG_STATE_HOME HOME="$src" "$backup" --pubkeys "$pubkeys" --no-host-key "$@" )
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
if ( cd "$checkout" && env -u XDG_STATE_HOME HOME="$src" "$backup" --pubkeys "$partialkeys" --no-host-key ) >/dev/null 2>&1; then
  fail "archived a partial set without --allow-incomplete"
fi
( cd "$checkout" && env -u XDG_STATE_HOME HOME="$src" "$backup" --pubkeys "$partialkeys" --no-host-key --allow-incomplete ) >/dev/null

# The host key is the host's sops identity: it must travel in the bundle, be
# restorable into the checkout `install` reads, and the recipient must match
# `&<host>` in .sops.yaml at backup time as well as at restore time.
test_host="$(uname -n)"
test_host="${test_host%%.*}"

hkdir="$root/hk"
mkdir -p "$hkdir"
ssh-keygen -q -t ed25519 -N "" -C "test host key" -f "$hkdir/ssh_host_ed25519_key"
hk_recipient="$(ssh-to-age -i "$hkdir/ssh_host_ed25519_key.pub")"

hk_sops="$root/hk-sops.yaml"
printf 'keys:\n  - &%s %s\n' "$test_host" "$hk_recipient" >"$hk_sops"
hk_checkout="$root/hk-checkout"
mkdir -p "$hk_checkout"
: >"$hk_checkout/flake.nix"
cp "$hk_sops" "$hk_checkout/.sops.yaml"

hk_state="$root/hk-state"
run_hk_backup() {
  ( cd "$hk_checkout" && env XDG_STATE_HOME="$hk_state" HOME="$src" "$backup" \
    --pubkeys "$pubkeys" --host-key-path "$hkdir/ssh_host_ed25519_key" "$@" )
}

run_hk_backup >/dev/null
hk_archive=$(find "$hk_state/key-backup" -name '*.tar.gz' -print -quit)
[ -n "$hk_archive" ] || fail "key-backup --host-key-path wrote no archive"
hk_contents="$(tar -tzf "$hk_archive")"
grep -qF "etc/ssh/ssh_host_ed25519_key" <<<"$hk_contents" || fail "bundle is missing the host key"
grep -qF "etc/ssh/ssh_host_ed25519_key.pub" <<<"$hk_contents" || fail "bundle is missing the host key's public half"
hk_manifest="$(tar -xOzf "$hk_archive" ./MANIFEST)"
grep -qE '^host-key: yes$' <<<"$hk_manifest" || fail "MANIFEST does not record the host key"
grep -qF "the host SSH key" <<<"$hk_manifest" || fail "MANIFEST does not describe the host key it holds"
grep -qF "host-key-recipient: $hk_recipient" <<<"$hk_manifest" \
  || fail "MANIFEST does not record the derived recipient"
[ "$(awk -F ': ' '/^host: /{print $2}' <<<"$hk_manifest")" = "$test_host" ] \
  || fail "MANIFEST records the wrong host"

hk_home="$root/hk-home"
mkdir -p "$hk_home"
hk_dest="$root/hk-target/etc/ssh"
run_hk_restore() {
  env -u XDG_STATE_HOME HOME="$hk_home" "$restore" --pubkeys "$pubkeys" "$@"
}

run_hk_restore --sops-file "$hk_sops" "$hk_archive" --host-key \
  --target-dir "$hk_dest" >/dev/null
cmp "$hkdir/ssh_host_ed25519_key" "$hk_dest/ssh_host_ed25519_key" \
  || fail "restored host key differs"
[ "$(mode "$hk_dest/ssh_host_ed25519_key")" = "-rw-------" ] || fail "host key is not 0600"
[ "$(mode "$hk_dest/ssh_host_ed25519_key.pub")" = "-rw-r--r--" ] || fail "host key public is not 0644"
[ ! -e "$hk_home/.config/ssh-sk" ] || fail "--host-key installed handles"

if run_hk_restore --sops-file "$hk_sops" "$hk_archive" --host-key \
  --target-dir "$hk_dest" >/dev/null 2>&1; then
  fail "overwrote the host key without --force"
fi

# The documented default destination: cwd is a checkout with flake.nix, and
# install reads secrets/hosts/<host>/ from there.
run_restore_checkout() {
  ( cd "$hk_checkout" && env -u XDG_STATE_HOME HOME="$hk_home" "$restore" \
    --pubkeys "$pubkeys" "$@" )
}
run_restore_checkout "$hk_archive" --host-key >/dev/null
default_dest="$hk_checkout/secrets/hosts/$test_host/etc/ssh/ssh_host_ed25519_key"
[ -f "$default_dest" ] || fail "--host-key did not write the default secrets/hosts/<host>/ path"
[ "$(mode "$default_dest")" = "-rw-------" ] || fail "default host key is not 0600"

# Outside a checkout, with no --target-dir, it must refuse rather than scatter
# secrets/hosts/ into the current directory.
nodir="$root/no-checkout"
mkdir -p "$nodir"
if (
  cd "$nodir"
  env -u XDG_STATE_HOME HOME="$hk_home" "$restore" --pubkeys "$pubkeys" \
    --sops-file "$hk_sops" "$hk_archive" --host-key >/dev/null 2>&1
); then
  fail "--host-key ran outside a checkout"
fi
[ ! -e "$nodir/secrets" ] || fail "--host-key wrote outside a checkout"

# The recipient check fails closed: no anchor, or no .sops.yaml at all.
noanchor="$root/no-anchor.yaml"
printf 'keys:\n  - &other %s\n' "$hk_recipient" >"$noanchor"
if run_hk_restore --sops-file "$noanchor" "$hk_archive" --host-key \
  --target-dir "$root/hk-nomatch" >/dev/null 2>&1; then
  fail "installed a host key with no &<host> anchor"
fi
if run_hk_restore --sops-file "$root/absent.yaml" "$hk_archive" --host-key \
  --target-dir "$root/hk-nosops" >/dev/null 2>&1; then
  fail "installed a host key with no .sops.yaml"
fi

# A host key the host's secrets are not encrypted to must be refused, and
# --force must not turn that check off.
wrongsops="$root/wrong-sops.yaml"
printf 'keys:\n  - &%s %s\n' "$test_host" "age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq" >"$wrongsops"
if run_hk_restore --sops-file "$wrongsops" "$hk_archive" --host-key \
  --target-dir "$root/hk-wrong" >/dev/null 2>&1; then
  fail "installed a host key that does not match .sops.yaml"
fi
if run_hk_restore --sops-file "$wrongsops" "$hk_archive" --host-key \
  --target-dir "$root/hk-wrong" --force >/dev/null 2>&1; then
  fail "--force disabled the .sops.yaml recipient check"
fi

# A MANIFEST host name that escapes secrets/hosts/ is refused even when the
# attacker also supplies a matching anchor.
evil="$root/evil"
mkdir -p "$evil"
tar -C "$evil" -xzf "$hk_archive"
awk '/^host: /{ print "host: ../../pwned"; next } { print }' "$evil/MANIFEST" >"$evil/MANIFEST.new"
mv "$evil/MANIFEST.new" "$evil/MANIFEST"
tar -C "$evil" -czf "$root/evil.tar.gz" .
evilsops="$root/evil-sops.yaml"
printf 'keys:\n  - &../../pwned %s\n' "$hk_recipient" >"$evilsops"
if run_hk_restore --sops-file "$evilsops" "$root/evil.tar.gz" --host-key \
  --no-verify --target-dir "$root/hk-evil" >/dev/null 2>&1; then
  fail "restored a key for an escaping MANIFEST host name"
fi

# Without a host key in the archive the mode fails instead of writing nothing.
if run_hk_restore --sops-file "$hk_sops" "$archive" --host-key \
  --target-dir "$root/hk-missing" >/dev/null 2>&1; then
  fail "--host-key accepted a bundle without a host key"
fi

# Backups made with --no-host-key stay valid and say so.
no_hk_manifest="$(tar -xOzf "$archive" ./MANIFEST)"
grep -qE '^host-key: no$' <<<"$no_hk_manifest" \
  || fail "--no-host-key backups do not record the missing host key"
grep -qF "handles only" <<<"$no_hk_manifest" \
  || fail "a host-key-less MANIFEST still claims to hold the host key"

# Backup-side recipient checks fail closed.
if (
  cd "$root"
  env -u XDG_STATE_HOME HOME="$src" "$backup" --pubkeys "$pubkeys" \
    --host-key-path "$hkdir/ssh_host_ed25519_key" >/dev/null 2>&1
); then
  fail "key-backup archived the host key without .sops.yaml"
fi
noanchor_checkout="$root/hk-noanchor"
mkdir -p "$noanchor_checkout"
: >"$noanchor_checkout/flake.nix"
printf 'keys:\n  - &other %s\n' "$hk_recipient" >"$noanchor_checkout/.sops.yaml"
if (
  cd "$noanchor_checkout"
  env XDG_STATE_HOME="$root/hk-bad-state" HOME="$src" "$backup" --pubkeys "$pubkeys" \
    --host-key-path "$hkdir/ssh_host_ed25519_key" >/dev/null 2>&1
); then
  fail "key-backup archived a host key with no &<host> anchor"
fi
mismatch_checkout="$root/hk-mismatch"
mkdir -p "$mismatch_checkout"
: >"$mismatch_checkout/flake.nix"
printf 'keys:\n  - &%s %s\n' "$test_host" "age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq" >"$mismatch_checkout/.sops.yaml"
if (
  cd "$mismatch_checkout"
  env XDG_STATE_HOME="$root/hk-bad-state" HOME="$src" "$backup" --pubkeys "$pubkeys" \
    --host-key-path "$hkdir/ssh_host_ed25519_key" >/dev/null 2>&1
); then
  fail "key-backup archived a host key that does not match .sops.yaml"
fi
if (
  cd "$hk_checkout"
  env XDG_STATE_HOME="$root/hk-bad-state" HOME="$src" "$backup" --pubkeys "$pubkeys" \
    --no-host-key >/dev/null 2>&1
); then
  fail "key-backup let --no-host-key skip a host that .sops.yaml binds"
fi

# An unreadable host key aborts the backup instead of producing a bundle that
# silently lacks the sops identity.
printf 'not a private key\n' >"$root/badkey"
if run_hk_backup --host-key-path "$root/badkey" >/dev/null 2>&1; then
  fail "archived a bundle after failing to read the host key"
fi
if run_hk_backup --host-key-path "$root/does-not-exist" >/dev/null 2>&1; then
  fail "archived a bundle for a missing host key path"
fi

# A machine with no enrolled handles can still archive its host key.
onlykeys="$root/only-keys"
: >"$onlykeys"
( cd "$hk_checkout" && env XDG_STATE_HOME="$root/only-state" HOME="$src" "$backup" \
  --pubkeys "$onlykeys" --host-key-path "$hkdir/ssh_host_ed25519_key" ) >/dev/null
only_archive=$(find "$root/only-state/key-backup" -name '*.tar.gz' -print -quit)
[ -n "$only_archive" ] || fail "key-backup refused a host-key-only backup"
grep -qE '^handles: 0$' <<<"$(tar -xOzf "$only_archive" ./MANIFEST)" \
  || fail "host-key-only backup does not record zero handles"
