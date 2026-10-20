#!/usr/bin/env bash
# Parse and exercise the resticprofile file generated for backup-photos.
#
# Usage: bash tests/backup_restic_smoke.sh <file-with-the-unit-ExecStart>
#
# The generated profile is copied into a temporary tree with local paths and a
# local rclone remote named `proton`, so the real backup/retention/check/copy
# flow and both markers run without root, Proton, or /var/backup. This catches
# a profile that resticprofile cannot parse, a hook typo, and a broker marker
# path, none of which `nix eval` would see.
set -euo pipefail

exec_start_file=${1:?usage: backup_restic_smoke.sh <file-with-ExecStart>}
profile=$(grep -o '/nix/store/[^ "]*backup-photos-resticprofile\.toml' "$exec_start_file" | head -n 1)
[[ -n $profile && -f $profile ]] || {
  echo "generated resticprofile file not found in $exec_start_file" >&2
  exit 1
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"

mkdir -p src/sub staging backup cache proton home "$tmp/repo"
echo test-password >pw
echo test-password >"$tmp/repo/password"
printf 'a' >src/a.txt
printf 'b' >src/sub/b.txt
printf 'dump' >staging/immich.sql.gz
printf '[proton]\ntype = alias\nremote = %s/proton\n' "$tmp" >rclone.conf

sed -e "s#/var/backup/restic/Photos#$tmp/repo#g" \
  -e "s#/run/secrets/restic-password#$tmp/pw#g" \
  -e "s#/var/cache/restic#$tmp/cache#g" \
  -e "s#/var/lib/media/Photos#$tmp/src#g" \
  -e "s#/var/lib/restic-staging/photos#$tmp/staging#g" \
  -e "s#/var/lib/backup/rclone.conf#$tmp/rclone.conf#g" \
  -e "s#/var/backup/Photos#$tmp/backup#g" \
  "$profile" >profiles.toml

export HOME="$tmp/home"

resticprofile --config profiles.toml --name photos backup >run1.log 2>&1 || {
  cat run1.log >&2
  exit 1
}
test -f backup/BACKUP-LAST-SUCCESS || {
  echo "success marker missing" >&2
  exit 1
}
test ! -e backup/BACKUP-FAILED || {
  echo "failure marker present after success" >&2
  exit 1
}
test -d proton/restic/Photos || {
  echo "no Proton byte copy" >&2
  exit 1
}

# The weekly full check must parse the check section too.
resticprofile --config profiles.toml --name photos check >check.log 2>&1 || {
  cat check.log >&2
  exit 1
}

restic -r "$tmp/repo" --password-file "$tmp/pw" restore latest --target "$tmp/restore" >/dev/null
cmp src/a.txt "restore$tmp/src/a.txt"
cmp staging/immich.sql.gz "restore$tmp/staging/immich.sql.gz"

# The Proton copy is itself a readable repository.
restic -r "$tmp/proton/restic/Photos" --password-file "$tmp/pw" restore latest --target "$tmp/proton-restore" >/dev/null
cmp src/a.txt "proton-restore$tmp/src/a.txt"

# A second snapshot reflects a modification and a deletion.
printf 'a2' >src/a.txt
rm src/sub/b.txt
resticprofile --config profiles.toml --name photos backup >run2.log 2>&1
restic -r "$tmp/repo" --password-file "$tmp/pw" restore latest --target "$tmp/restore2" >/dev/null
cmp src/a.txt "restore2$tmp/src/a.txt"
test ! -e "restore2$tmp/src/sub/b.txt" || {
  echo "deleted file is back in the newest snapshot" >&2
  exit 1
}

# A failed backup clears the success marker and leaves BACKUP-FAILED.
echo wrong >wrongpw
sed -e "s#$tmp/pw#$tmp/wrongpw#" -e "s#$tmp/repo/password#$tmp/wrongpw#" profiles.toml >wrong.toml
if resticprofile --config wrong.toml --name photos backup >fail.log 2>&1; then
  echo "wrong-password backup unexpectedly succeeded" >&2
  exit 1
fi
test -f backup/BACKUP-FAILED || {
  echo "failure marker missing" >&2
  cat fail.log >&2
  exit 1
}
test ! -e backup/BACKUP-LAST-SUCCESS || {
  echo "success marker not cleared after failure" >&2
  exit 1
}

echo "backup_restic_smoke.sh: ok"
