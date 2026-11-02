#!/usr/bin/env bash
# One-shot Proton Drive -> Cryptomator vault migration (T1, sdlc #295).
# The vault must already exist (cryptomator-cli cannot create one).
# Copies only; never deletes source data.
set -euo pipefail

usage() {
  cat <<'EOF'
usage: migrate-vault.sh --vault PATH --mount PATH [--source PATH] [--dry-run]

  --vault   existing Cryptomator vault directory (ciphertext)
  --mount   empty, writable mount point for the unlocked vault
  --source  Proton Drive mount (default /srv/proton)
  --mounter Cryptomator mounter class (default LinuxFuse on Linux)
  --dry-run print the plan without copying

Prompts for the vault password on the terminal. Requires cryptomator-cli,
rsync and fusermount3.
EOF
}

vault="" mount="" source="/srv/proton" mounter="" dry_run=0
while [ $# -gt 0 ]; do
  case "$1" in
    --vault) vault=$2; shift 2 ;;
    --mount) mount=$2; shift 2 ;;
    --source) source=$2; shift 2 ;;
    --mounter) mounter=$2; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[ -n "$vault" ] && [ -n "$mount" ] || { usage >&2; exit 2; }

folders=(Documents Archive Furry "Sheet Music" Origami Videos)

for f in "${folders[@]}"; do
  [ -d "$source/$f" ] || { echo "missing source folder: $source/$f" >&2; exit 1; }
done
[ -f "$vault/vault.cryptomator" ] || { echo "not a Cryptomator vault: $vault" >&2; exit 1; }

if [ "$dry_run" = 1 ]; then
  for f in "${folders[@]}"; do
    printf 'would copy %s/ -> %s/%s/ (%s files)\n' "$source/$f" "$mount" "$f" \
      "$(find "$source/$f" -type f | wc -l)"
  done
  exit 0
fi

[ -d "$mount" ] || { echo "mount point does not exist: $mount" >&2; exit 1; }
[ -z "$(ls -A "$mount")" ] || { echo "mount point is not empty: $mount" >&2; exit 1; }

if [ -z "$mounter" ]; then
  case "$(uname -s)" in
    Linux) mounter=org.cryptomator.frontend.fuse.mount.LinuxFuseMountProvider ;;
    *) echo "pass --mounter on $(uname -s)" >&2; exit 2 ;;
  esac
fi

read -rsp "Vault password: " VAULT_PASS
echo
export VAULT_PASS

cryptomator-cli unlock --mounter="$mounter" --mountPoint="$mount" --password:env=VAULT_PASS "$vault" &
cli_pid=$!
cleanup() {
  fusermount3 -u "$mount" 2>/dev/null || true
  kill "$cli_pid" 2>/dev/null || true
  wait "$cli_pid" 2>/dev/null || true
}
trap cleanup EXIT

for _ in $(seq 1 60); do
  mountpoint -q "$mount" && break
  sleep 1
done
mountpoint -q "$mount" || { echo "vault did not mount" >&2; exit 1; }

for f in "${folders[@]}"; do
  echo "== copying $f"
  rsync -rlt --no-owner --no-group --no-perms --info=stats2 "$source/$f/" "$mount/$f/"
done

echo "== verifying (file counts and byte-level diff)"
status=0
for f in "${folders[@]}"; do
  src_count=$(find "$source/$f" -type f | wc -l)
  dst_count=$(find "$mount/$f" -type f | wc -l)
  if [ "$src_count" != "$dst_count" ]; then
    echo "COUNT MISMATCH $f: source=$src_count vault=$dst_count" >&2
    status=1
  fi
  report=$(mktemp)
  if ! diff -rq "$source/$f" "$mount/$f" >"$report" 2>&1; then
    echo "CONTENT MISMATCH $f:" >&2
    sed -n '1,20p' "$report" >&2
    status=1
  fi
  rm -f "$report"
  [ "$status" = 0 ] && echo "ok $f ($src_count files)"
done
exit "$status"
