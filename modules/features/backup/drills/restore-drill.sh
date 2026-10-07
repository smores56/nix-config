#!/usr/bin/env bash
# Restore drill for a dotfiles.backup dataset: prove the local mirror and the
# offsite mirror are faithful copies of the live source, and (optionally)
# restore a dataset's database dump into a scratch Postgres and assert the
# restore is faithful and complete (expected tables present with rows).
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
# add the exhaustive walk (`rclone check`), which is slow but streams progress.
#
# The whole drill holds the same host-wide flock the driver takes, because every
# dataset shares one Proton credential and two concurrent rclone clients blank
# the single-use refresh token (rclone#9880).
#
# Env overrides (defaults match the smortress datasets):
#   RCLONE CONF            rclone binary and config
#   SRC LOC REMOTE         source dir, local mirror, remote path
#   N                      files hashed source-vs-local (default 20)
#   OFFN                   named files restored from offsite (default 3)
#   EXCLUDES               rclone exclude args (defaults to the unit's, else drops .cache + secrets)
#   FETCH_TIMEOUT          seconds allowed per offsite file fetch (default 300)
#   FULL_OFFSITE=1         also walk the whole remote (slow)
#   DRILL_ONLY_DB=1        skip the media phases and only check the database
#                          (requires DRILL_PG_DB)
#   DRILL_PG_DB            live database (its counts are informational only)
#   DRILL_PG_DUMP          dump to restore (default: newest <LOC>/db/*.dump)
#   DRILL_PG_TABLES        tables that must exist with rows after restore (default: asset)
#   DRILL_PG_QUERY         informational count query run against the live database
#   MEDIA_BACKUP_LOCK      lock path (default /run/lock/media-backup.lock; test-only)
set -euo pipefail

NAME=${1:?usage: restore-drill.sh <Dataset> [samples]}
N=${2:-${N:-20}}
OFFN=${OFFN:-3}
FETCH_TIMEOUT=${FETCH_TIMEOUT:-300}
FULL_OFFSITE=${FULL_OFFSITE:-0}
DRILL_ONLY_DB=${DRILL_ONLY_DB:-0}

RCLONE=${RCLONE:-rclone}
CONF=${CONF:-/var/lib/backup/rclone.conf}
# Same host-wide lock the driver (backup.py) takes.
LOCK=${MEDIA_BACKUP_LOCK:-/run/lock/media-backup.lock}

# These mirror backup.py's NETWORK_FLAGS / STATS_FLAGS and _UNCHECKED_RE.
# Keep in sync with backup.py; a divergent copy silently weakens the drill.
NET=(--timeout 5m --contimeout 30s --retries 5 --low-level-retries 20 --retries-sleep 10s)
STATS=(--stats 30s --stats-log-level NOTICE)
# _UNCHECKED_RE is PCRE (`\d`), so it is matched with `grep -P`.
UNCHECKED_RE='(\d+) hashes could not be checked'

# Derive the dataset's real config from the deployed unit instead of guessing:
# backup-<name>.service ExecStart carries --source, --remote and --exclude.
# Env overrides still win; fall back to the defaults only when the unit is absent.
UNIT="backup-${NAME,,}.service"
unit_args=()
if command -v systemctl >/dev/null 2>&1; then
  exec_start=$(systemctl show "$UNIT" -p ExecStart --value 2>/dev/null || true)
  case $exec_start in
    *'argv[]='*)
      argv=${exec_start#*argv[]=}
      argv=${argv%% ;*}
      mapfile -t unit_args < <(printf '%s\n' "$argv" | xargs -n1 2>/dev/null || true)
      ;;
  esac
fi
unit_source=
unit_remote=
unit_excludes=()
for ((i = 0; i < ${#unit_args[@]}; i++)); do
  case ${unit_args[i]} in
    --source)
      if [ $((i + 1)) -lt ${#unit_args[@]} ]; then unit_source=${unit_args[i + 1]}; fi
      ;;
    --remote)
      if [ $((i + 1)) -lt ${#unit_args[@]} ]; then unit_remote=${unit_args[i + 1]}; fi
      ;;
    --exclude)
      if [ $((i + 1)) -lt ${#unit_args[@]} ]; then unit_excludes+=("${unit_args[i + 1]}"); fi
      ;;
  esac
done

SRC=${SRC:-${unit_source:-/var/lib/media/$NAME}}
LOC=${LOC:-/var/backup/$NAME/current}
REMOTE=${REMOTE:-${unit_remote:+${unit_remote}:${NAME}}}
REMOTE=${REMOTE:-proton:$NAME}

# Exclude args, in priority order: EXCLUDES env, the unit's --exclude list, the
# smortress defaults. Kept as an array so patterns with spaces stay intact.
if [ -n "${EXCLUDES:-}" ]; then
  read -r -a EXCL_ARGS <<< "$EXCLUDES"
elif [ ${#unit_excludes[@]} -gt 0 ]; then
  EXCL_ARGS=()
  for pattern in "${unit_excludes[@]}"; do EXCL_ARGS+=(--exclude "$pattern"); done
else
  EXCL_ARGS=(--exclude '**/.cache/**' --exclude '/rclone.conf')
fi

[ "$DRILL_ONLY_DB" = 1 ] && [ -z "${DRILL_PG_DB:-}" ] &&
  { echo "DRILL_ONLY_DB=1 requires DRILL_PG_DB"; exit 2; }

DRILL=${DRILL_DB:-${DRILL_PG_DB:-drill}_drill}
if [ -n "${DRILL_PG_DB:-}" ]; then
  # Never dropdb a live database: refuse an explicit scratch name that is the
  # live DB, and refuse to clobber any pre-existing database that is not named
  # like a *_drill scratch (we cannot know it is disposable otherwise).
  if [ "$DRILL" = "$DRILL_PG_DB" ]; then
    echo "refusing: scratch database '$DRILL' would be the live database"; exit 2
  fi
  if ! [[ $DRILL =~ ^[A-Za-z0-9_]+$ ]]; then
    echo "refusing: invalid scratch database name '$DRILL'"; exit 2
  fi
  if [[ $DRILL != *_drill ]]; then
    if runuser -u postgres -- psql -tAc "select 1 from pg_database where datname = '$DRILL'" 2>/dev/null | grep -q 1; then
      echo "refusing: database '$DRILL' exists and is not a *_drill scratch DB"; exit 2
    fi
  fi
fi

# Take the lock before any rclone call. The file must be root-owned 0600;
# create it that way, then hold fd 9 for the rest of the drill.
(umask 077; : >> "$LOCK")
chmod 0600 "$LOCK"
exec 9>>"$LOCK"
if ! flock -n 9; then
  echo "waiting for lock $LOCK (another backup/drill holds it)..."
  flock 9
  echo "lock acquired"
fi

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
# Buffered, not `rclone version | head -1`: head closing the pipe SIGPIPEs
# rclone and pipefail then aborts the script.
"$RCLONE" version > "$TMP/version" 2>&1 || true
head -1 "$TMP/version" || true
echo

fail=0
step() { echo "== $1 =="; }

if [ "$DRILL_ONLY_DB" != 1 ]; then
  # Files the backup actually mirrors. rclone applies the same exclude patterns
  # it applies to the copy, so the sample is exactly what is in the mirror (N5).
  # Filenames may contain spaces or glob characters, so the list is read into an
  # array and every use is quoted.
  if ! "$RCLONE" lsf "$SRC" --recursive --files-only --config "$CONF" "${EXCL_ARGS[@]}" 2>/dev/null \
    | shuf -n "$N" > "$TMP/list"; then
    fail=$((fail + 1)); echo "FAIL could not list source $SRC"
  fi
  mapfile -t samples < "$TMP/list"

  step "1: source vs local (size/count + $N sha256)"
  printf '%-10s ' source; "$RCLONE" size "$SRC" --config "$CONF" "${EXCL_ARGS[@]}" 2>/dev/null \
    | sed -E 's/Total objects: /n=/; s/Total size: /bytes=/' | tr '\n' ' '; echo
  printf '%-10s ' local; "$RCLONE" size "$LOC" --config "$CONF" "${EXCL_ARGS[@]}" 2>/dev/null \
    | sed -E 's/Total objects: /n=/; s/Total size: /bytes=/' | tr '\n' ' '; echo
  for rel in "${samples[@]}"; do
    if [ "$(sha256sum "$SRC/$rel" | cut -d' ' -f1)" = "$(sha256sum "$LOC/$rel" | cut -d' ' -f1)" ]; then
      echo "OK   local  $rel"
    else
      fail=$((fail + 1)); echo "FAIL local  $rel"
    fi
  done
  echo

  step "2: offsite restore sample ($OFFN files, path-resolved — no full traversal)"
  # `rclone copyto` on one path resolves only that path's directories, so this
  # stays cheap on a large remote. A `--files-from` copy would re-walk every
  # object (minutes on a 30k-object Proton tree).
  mapfile -t off_samples < <(shuf -n "$OFFN" "$TMP/list")
  for rel in "${off_samples[@]}"; do
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
    # `rclone check` already traverses every object, so there is no separate
    # `rclone size` walk here (that would walk the remote twice).
    step "3: offsite walk (slow — every object on the remote)"
    echo "running: rclone check --checksum --one-way local offsite"
    check_rc=0
    check_out=$("$RCLONE" check --checksum --one-way "$LOC" "$REMOTE" \
      --config "$CONF" "${NET[@]}" "${STATS[@]}" "${EXCL_ARGS[@]}" 2>&1) || check_rc=$?
    printf '%s\n' "$check_out" | tail -5
    # A non-zero exit means files differ or are missing; do not swallow it.
    if [ "$check_rc" -ne 0 ]; then
      fail=$((fail + 1)); echo "FAIL rclone check exit=$check_rc (files differ or missing)"
    fi
    # rclone exits 0 even when it compared nothing, so also fail when it reports
    # unchecked hashes (same regex as backup.py's _UNCHECKED_RE).
    unchecked=$(printf '%s\n' "$check_out" | grep -oP "$UNCHECKED_RE" | grep -oP '^\d+' | head -1 || true)
    if [ -n "$unchecked" ] && [ "$unchecked" -gt 0 ]; then
      fail=$((fail + 1)); echo "FAIL could not verify every object ($unchecked files unchecked)"
    fi
    echo
  fi
fi

if [ -n "${DRILL_PG_DB:-}" ]; then
  step "database restore into scratch postgres"
  # Newest dump by name: the filenames are immich-<ISO timestamp>.dump, so a
  # plain sorted glob is chronological (avoids `ls`, cf. shellcheck SC2012).
  DUMP=${DRILL_PG_DUMP:-}
  if [ -z "$DUMP" ]; then
    shopt -s nullglob
    dumps=("$LOC"/db/*.dump)
    shopt -u nullglob
    DUMP=${dumps[${#dumps[@]}-1]:-}
  fi
  if [ -z "$DUMP" ]; then
    fail=$((fail + 1)); echo "FAIL no dump under $LOC/db"
  else
    echo "dump: $DUMP ($(stat -c %s "$DUMP") bytes, $(stat -c %y "$DUMP"))"
  fi
  # Informational only: the live DB keeps changing after the dump, so its counts
  # are printed for the operator and never used as a pass/fail criterion.
  QUERY=${DRILL_PG_QUERY:-"select (select count(*) from asset) as assets, (select count(*) from album) as albums, (select count(*) from person) as people, (select count(*) from asset_face) as faces;"}
  # A faithful, complete restore is asserted instead: pg_restore succeeded and
  # the restored DB holds the expected tables with non-zero rows.
  TABLES=${DRILL_PG_TABLES:-asset}
  runuser -u postgres -- dropdb --if-exists "$DRILL"
  runuser -u postgres -- createdb -O postgres "$DRILL"
  # The dump sits behind the 0700 backup directory, which the postgres user
  # cannot read; root opens it and streams it in on stdin instead.
  if runuser -u postgres -- pg_restore --no-owner -d "$DRILL" < "$DUMP"; then
    echo "OK   pg_restore $DUMP"
  else
    fail=$((fail + 1)); echo "FAIL pg_restore $DUMP"
  fi
  for table in $TABLES; do
    rows=$(runuser -u postgres -- psql -d "$DRILL" -tAc "select count(*) from \"$table\"" 2>/dev/null || true)
    if [ -n "$rows" ] && [ "$rows" -gt 0 ] 2>/dev/null; then
      echo "OK   table $table rows=$rows"
    else
      fail=$((fail + 1)); echo "FAIL table $table missing or empty (rows=${rows:-none})"
    fi
  done
  echo "INFORMATION live counts (not a pass/fail criterion): $(runuser -u postgres -- psql -d "$DRILL_PG_DB" -tAc "$QUERY" 2>/dev/null || true)"
  runuser -u postgres -- dropdb "$DRILL"
  echo
fi

if [ "$fail" -eq 0 ]; then
  echo "DRILL PASS"
else
  echo "DRILL FAIL ($fail checks)"
  exit 1
fi
