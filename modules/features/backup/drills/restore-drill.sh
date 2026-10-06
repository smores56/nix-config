#!/usr/bin/env bash
# Restore drill for a dotfiles.backup dataset: prove the local mirror and the
# offsite mirror are byte-faithful copies of the live source, and (optionally)
# restore a dataset's database dump into a scratch Postgres and compare counts.
#
# This is the executable form of the "Restore procedure" in ../README.md. Run it
# as root (the mirrors are mode 0700):
#
#   sudo bash restore-drill.sh Photos
#   DRILL_PG_DB=immich sudo bash restore-drill.sh Photos
#
# Usage: restore-drill.sh <Dataset> [samples]
#   Dataset  name of a dotfiles.backup.datasets.<Dataset> entry (e.g. Photos)
#   samples  files to hash-compare across source/local/offsite (default 20)
#
# Env overrides (defaults match the smortress datasets):
#   RCLONE CONF            rclone binary and config
#   SRC LOC REMOTE         source dir, local mirror, remote path
#   EXCLUDES               extra rclone exclude args (default drops .cache + secrets)
#   DRILL_PG_DB            live database to compare against; enables the DB phase
#   DRILL_PG_DUMP          dump to restore (default: newest <LOC>/db/*.dump)
#   DRILL_PG_QUERY         count query run against both databases
set -euo pipefail

NAME=${1:?usage: restore-drill.sh <Dataset> [samples]}
N=${2:-${N:-20}}

RCLONE=${RCLONE:-rclone}
CONF=${CONF:-/var/lib/backup/rclone.conf}
SRC=${SRC:-/var/lib/media/$NAME}
LOC=${LOC:-/var/backup/$NAME/current}
REMOTE=${REMOTE:-proton:$NAME}
# shellcheck disable=SC2086  # intentionally word-split into rclone args
EXCLUDES=${EXCLUDES:---exclude **/.cache/** --exclude /rclone.conf}

DRILL=${DRILL_DB:-${DRILL_PG_DB:-drill}_drill}
TMP=$(mktemp -d "/tmp/restore-drill.XXXXXX")
cleanup() {
  rm -rf "$TMP"
  [ -n "${DRILL_PG_DB:-}" ] && runuser -u postgres -- dropdb --if-exists "$DRILL" 2>/dev/null
  return 0
}
trap cleanup EXIT

command -v "$RCLONE" >/dev/null || { echo "rclone not found: $RCLONE"; exit 1; }
[ -d "$SRC" ] || { echo "no such source: $SRC (override with SRC=)"; exit 1; }

echo "host: $(hostname)  dataset: $NAME  date: $(date -Is)"
echo "source=$SRC"
echo "local=$LOC"
echo "remote=$REMOTE"
"$RCLONE" version | head -1
echo

echo "== 1/3 size/count parity: source vs local current vs offsite =="
size_of() {
  "$RCLONE" size "$1" --config "$CONF" ${2:-} 2>/dev/null \
    | sed -E 's/Total objects: /n=/; s/Total size: /bytes=/' | tr '\n' ' '
  echo
}
printf '%-10s ' source; size_of "$SRC" "$EXCLUDES"
printf '%-10s ' local; size_of "$LOC" "$EXCLUDES"
printf '%-10s ' offsite; size_of "$REMOTE"
echo

echo "== 2/3 content sample ($N files): source vs local vs offsite (sha256) =="
(
  cd "$SRC" && find . -type f ! -path '*/.cache/*' ! -name rclone.conf \
    | shuf | head -n "$N" | sed 's|^\./||'
) > "$TMP/list"
# One Proton session for every sample: --no-traverse fetches each name directly,
# instead of re-listing the remote once per file.
"$RCLONE" copy "$REMOTE" "$TMP/off" --config "$CONF" \
  --files-from "$TMP/list" --no-traverse --transfers 4 -q

pass=0; fail=0
while IFS= read -r rel; do
  src_sum=$(sha256sum "$SRC/$rel" | cut -d' ' -f1)
  loc_sum=$(sha256sum "$LOC/$rel" | cut -d' ' -f1)
  if [ ! -e "$TMP/off/$rel" ]; then
    fail=$((fail + 1)); echo "MISSING offsite: $rel"; continue
  fi
  off_sum=$(sha256sum "$TMP/off/$rel" | cut -d' ' -f1)
  if [ "$src_sum" = "$loc_sum" ] && [ "$src_sum" = "$off_sum" ]; then
    pass=$((pass + 1)); echo "OK   $rel"
  else
    fail=$((fail + 1)); echo "FAIL $rel src=$src_sum loc=$loc_sum off=$off_sum"
  fi
done < "$TMP/list"
echo "sample: $pass ok, $fail failed (of $N sampled)"
echo

if [ -n "${DRILL_PG_DB:-}" ]; then
  echo "== 3/3 database restore into scratch postgres =="
  DUMP=${DRILL_PG_DUMP:-$(ls -t "$LOC"/db/*.dump | head -1)}
  echo "dump: $DUMP ($(stat -c %s "$DUMP") bytes, $(stat -c %y "$DUMP"))"
  QUERY=${DRILL_PG_QUERY:-"select 'assets', count(*) from assets union all select 'albums', count(*) from albums union all select 'people', count(*) from person;"}
  counts() {
    runuser -u postgres -- psql -d "$1" -tAc "$QUERY" 2>/dev/null | paste -sd' '
  }
  runuser -u postgres -- dropdb --if-exists "$DRILL"
  runuser -u postgres -- createdb -O postgres "$DRILL"
  runuser -u postgres -- pg_restore --no-owner -d "$DRILL" "$DUMP"
  echo "live:  $(counts "$DRILL_PG_DB")"
  echo "drill: $(counts "$DRILL")"
  runuser -u postgres -- dropdb "$DRILL"
  echo
fi

[ "$fail" -eq 0 ] && echo "DRILL PASS" || { echo "DRILL FAIL"; exit 1; }
