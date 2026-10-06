#!/usr/bin/env bash
# Restore drill for a dotfiles.backup dataset: prove the local mirror and the
# offsite mirror are faithful copies of the live source, and (optionally)
# restore a dataset's database dump into a scratch Postgres and compare counts.
#
# This is the executable form of the "Restore procedure" in ../README.md. Run it
# as root (the mirrors are mode 0700):
#
#   sudo bash restore-drill.sh Photos
#   sudo DRILL_PG_DB=immich bash restore-drill.sh Photos
#
# Usage: restore-drill.sh <Dataset> [samples]
#   Dataset  name of a dotfiles.backup.datasets.<Dataset> entry (e.g. Photos)
#   samples  files to hash-compare source vs local vs offsite (default 20)
#
# Cost model: ANY offsite rclone operation walks the whole remote. On a 30k-object
# Proton tree a full walk takes minutes, so the default drill never does one — it
# restores a few named files by path (cheap) and relies on the nightly backup's
# own `rclone check` for whole-mirror content verification. Set FULL_OFFSITE=1 to
# add the exhaustive walk (offsite size parity + `rclone check`), which is slow
# but streams progress.
#
# Env overrides (defaults match the smortress datasets):
#   RCLONE CONF            rclone binary and config
#   SRC LOC REMOTE         source dir, local mirror, remote path
#   N                      files hashed source-vs-local (default 20)
#   OFFN                   named files restored from offsite (default 3)
#   EXCLUDES               rclone exclude args (default drops .cache + secrets)
#   FETCH_TIMEOUT          seconds allowed per offsite file fetch (default 300)
#   FULL_OFFSITE=1         also walk the whole remote (slow)
#   DRILL_PG_DB            live database to compare against; enables the DB phase
#   DRILL_PG_DUMP          dump to restore (default: newest <LOC>/db/*.dump)
#   DRILL_PG_QUERY         count query run against both databases
set -euo pipefail

NAME=${1:?usage: restore-drill.sh <Dataset> [samples]}
N=${2:-${N:-20}}
OFFN=${OFFN:-3}
FETCH_TIMEOUT=${FETCH_TIMEOUT:-300}
FULL_OFFSITE=${FULL_OFFSITE:-0}

RCLONE=${RCLONE:-rclone}
CONF=${CONF:-/var/lib/backup/rclone.conf}
SRC=${SRC:-/var/lib/media/$NAME}
LOC=${LOC:-/var/backup/$NAME/current}
REMOTE=${REMOTE:-proton:$NAME}
# shellcheck disable=SC2086  # intentionally word-split into rclone args
EXCLUDES=${EXCLUDES:---exclude **/.cache/** --exclude /rclone.conf}
# Same protections the backup uses: a wedged Proton session must not hang forever.
NET=(--timeout 5m --contimeout 30s --retries 3 --low-level-retries 20 --retries-sleep 10s)
STATS=(--stats 30s --stats-log-level NOTICE)

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
# `rclone version | head -1` races: head closing the pipe SIGPIPEs rclone and
# pipefail then aborts the script. Buffer the output and trim that instead.
"$RCLONE" version > "$TMP/version" 2>&1 || true
head -1 "$TMP/version" || true
echo

# N files that exist on the source, shared by the local and offsite samples.
# `shuf -n`, not `shuf | head`: head closing the pipe SIGPIPEs shuf, and
# `set -o pipefail` then aborts the whole drill on a large source tree.
(
  cd "$SRC" && find . -type f ! -path '*/.cache/*' ! -name rclone.conf \
    | shuf -n "$N" | sed 's|^\./||'
) > "$TMP/list"

fail=0
step() { echo "== $1 =="; }

step "1: source vs local (size/count + $N sha256)"
printf '%-10s ' source; "$RCLONE" size "$SRC" --config "$CONF" $EXCLUDES 2>/dev/null \
  | sed -E 's/Total objects: /n=/; s/Total size: /bytes=/' | tr '\n' ' '; echo
printf '%-10s ' local; "$RCLONE" size "$LOC" --config "$CONF" $EXCLUDES 2>/dev/null \
  | sed -E 's/Total objects: /n=/; s/Total size: /bytes=/' | tr '\n' ' '; echo
while IFS= read -r rel; do
  if [ "$(sha256sum "$SRC/$rel" | cut -d' ' -f1)" = "$(sha256sum "$LOC/$rel" | cut -d' ' -f1)" ]; then
    echo "OK   local  $rel"
  else
    fail=$((fail + 1)); echo "FAIL local  $rel"
  fi
done < "$TMP/list"
echo

step "2: offsite restore sample ($OFFN files, path-resolved — no full traversal)"
# `rclone copyto` on one path resolves only that path's directories, so this stays
# cheap on a large remote. A `--files-from` copy would re-walk every object.
for rel in $(shuf -n "$OFFN" "$TMP/list"); do
  dest="$TMP/off/$rel"
  mkdir -p "$(dirname "$dest")"
  printf 'fetch %s ... ' "$rel"
  if timeout "$FETCH_TIMEOUT" "$RCLONE" copyto "$REMOTE/$rel" "$dest" \
    --config "$CONF" "${NET[@]}" -q; then
    if [ "$(sha256sum "$SRC/$rel" | cut -d' ' -f1)" = "$(sha256sum "$dest" | cut -d' ' -f1)" ]; then
      echo "OK"
    else
      fail=$((fail + 1)); echo "FAIL (hash mismatch)"
    fi
  else
    fail=$((fail + 1)); echo "FAIL (fetch failed or timed out after ${FETCH_TIMEOUT}s)"
  fi
done
echo

if [ "$FULL_OFFSITE" = 1 ]; then
  step "3: offsite walk (slow — every object on the remote)"
  printf '%-10s ' offsite; "$RCLONE" size "$REMOTE" --config "$CONF" "${NET[@]}" 2>/dev/null \
    | sed -E 's/Total objects: /n=/; s/Total size: /bytes=/' | tr '\n' ' '; echo
  echo "running: rclone check --checksum --one-way local offsite"
  check_out=$("$RCLONE" check --checksum --one-way "$LOC" "$REMOTE" \
    --config "$CONF" "${NET[@]}" "${STATS[@]}" 2>&1) || true
  echo "$check_out" | tail -5
  if echo "$check_out" | grep -qE '[1-9][0-9]* hashes could not be checked'; then
    fail=$((fail + 1)); echo "FAIL could not verify every object"
  fi
  echo
fi

if [ -n "${DRILL_PG_DB:-}" ]; then
  step "database restore into scratch postgres"
  DUMP=${DRILL_PG_DUMP:-$(ls -t "$LOC"/db/*.dump 2>/dev/null | head -1 || true)}
  echo "dump: $DUMP ($(stat -c %s "$DUMP") bytes, $(stat -c %y "$DUMP"))"
  QUERY=${DRILL_PG_QUERY:-"select 'assets', count(*) from assets union all select 'albums', count(*) from albums union all select 'people', count(*) from person;"}
  counts() {
    runuser -u postgres -- psql -d "$1" -tAc "$QUERY" 2>/dev/null | paste -sd' '
  }
  runuser -u postgres -- dropdb --if-exists "$DRILL"
  runuser -u postgres -- createdb -O postgres "$DRILL"
  # The dump sits behind the 0700 backup directory, which the postgres user
  # cannot read; root opens it and streams it in on stdin instead.
  runuser -u postgres -- pg_restore --no-owner -d "$DRILL" < "$DUMP"
  echo "live:  $(counts "$DRILL_PG_DB")"
  echo "drill: $(counts "$DRILL")"
  runuser -u postgres -- dropdb "$DRILL"
  echo
fi

[ "$fail" -eq 0 ] && echo "DRILL PASS" || { echo "DRILL FAIL ($fail checks)"; exit 1; }
