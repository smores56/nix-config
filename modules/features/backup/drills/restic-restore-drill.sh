#!/usr/bin/env bash
# Restore drill for a restic-driver dataset (Photos today). Proves that the
# local repository and the append-only Proton byte copy both restore readable
# bytes, that the escrowed password alone can open them with a clean home and
# cache, and that the staged PostgreSQL dump loads into a scratch database.
#
# Run as root (the repository and password are root-only):
#
#   sudo bash restic-restore-drill.sh                 # local repo only
#   sudo FULL_OFFSITE=1 bash restic-restore-drill.sh  # + Proton copy
#   sudo KEY_ONLY=1 bash restic-restore-drill.sh      # escrow: clean HOME/cache
#   sudo DRILL_PG_DB=photos_drill bash restic-restore-drill.sh
#
# This is the executable form of the restic restore procedure in ../README.md
# (the rclone datasets keep drills/restore-drill.sh until T12).
#
# Comparison rule: the restored bytes are compared with `restic dump` of the
# SAME snapshot, never with the live source. The source keeps changing after a
# snapshot, so a source-vs-latest compare would fail on healthy data. Set
# SOURCE_COMPARE=1 to additionally hash every sampled path that still exists in
# the source (unchanged files only; a changed source file is reported SKIP).
#
# The whole drill holds /run/lock/media-backup.lock: every dataset shares one
# Proton credential and two concurrent rclone clients blank the single-use
# refresh token (rclone#9880). It never writes BACKUP-LAST-SUCCESS, never
# deletes from the remote (rclone copies remote -> temp), and removes its temp
# tree unless KEEP=1.
#
# Env overrides (defaults match smortress / the Photos dataset):
#   DATASET             dataset name (default Photos)
#   REPO                local restic repository (default /var/backup/restic/Photos)
#   PASSWORD_FILE       restic password (default /run/secrets/restic-password)
#   SOURCE              live source tree (default /var/lib/media/Photos)
#   PROTON_PATH         rclone remote repo (default proton:restic/Photos)
#   RCLONE_CONFIG       rclone config (default /var/lib/backup/rclone.conf)
#   STAGING             snapshot path of the dump dir
#                       (default /var/lib/backup/restic-staging/<dataset lc>)
#   RESTORE_ROOT        per-run restore work dir (default /var/tmp/restic-drill)
#   PROTON_COPY         where to copy the Proton repo (default: inside the run dir)
#   SAMPLES             source files sampled per repo (default 3)
#   FULL_OFFSITE=1      also copy the Proton repo, check, restore and verify
#   KEY_ONLY=1          also restore with a clean HOME/cache and only the password
#   DRILL_PG_DB         scratch database for the Postgres dump restore
#   PG_DUMP_PATH        dump path inside the snapshot
#                       (default <STAGING>/immich.sql.gz)
#   SOURCE_COMPARE=1    also hash unchanged source files
#   KEEP=1              keep the temp tree (and a restored scratch DB)
#   MEDIA_BACKUP_LOCK   lock path (default /run/lock/media-backup.lock; test-only)
#
# Exit: 0 pass, 1 fail, 2 refused or a requested phase skipped (Postgres
# unavailable, DRILL_PG_DB=immich, ...).
set -euo pipefail

DATASET=${DATASET:-Photos}
REPO=${REPO:-/var/backup/restic/$DATASET}
PASSWORD_FILE=${PASSWORD_FILE:-/run/secrets/restic-password}
SOURCE=${SOURCE:-/var/lib/media/$DATASET}
PROTON_PATH=${PROTON_PATH:-proton:restic/$DATASET}
RCLONE_CONFIG=${RCLONE_CONFIG:-/var/lib/backup/rclone.conf}
staging_default=/var/lib/backup/restic-staging/$(printf '%s' "$DATASET" | tr '[:upper:]' '[:lower:]')
STAGING=${STAGING:-$staging_default}
RESTORE_ROOT=${RESTORE_ROOT:-/var/tmp/restic-drill}
FULL_OFFSITE=${FULL_OFFSITE:-0}
KEY_ONLY=${KEY_ONLY:-0}
DRILL_PG_DB=${DRILL_PG_DB:-}
KEEP=${KEEP:-0}
SAMPLES=${SAMPLES:-3}
SOURCE_COMPARE=${SOURCE_COMPARE:-0}
MEDIA_BACKUP_LOCK=${MEDIA_BACKUP_LOCK:-/run/lock/media-backup.lock}
PG_DUMP_PATH=${PG_DUMP_PATH:-$STAGING/immich.sql.gz}
PROTON_COPY=${PROTON_COPY:-}
RESTIC=${RESTIC:-restic}
RCLONE=${RCLONE:-rclone}

fail=0
pg_skipped=0
pg_db_created=0
proton_copy=
PG_RUN=()

step() { printf '\n== %s ==\n' "$*"; }
ok() { printf 'OK   %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }
bad() {
  fail=$((fail + 1))
  printf 'FAIL %s\n' "$*"
}
die() {
  printf 'FAIL %s\n' "$*" >&2
  exit 2
}

# Refuse unsafe scratch database names before touching anything.
if [ -n "$DRILL_PG_DB" ]; then
  if [ "$DRILL_PG_DB" = immich ]; then
    die "refusing DRILL_PG_DB=immich: the dump must never load into the live database"
  fi
  if ! [[ $DRILL_PG_DB =~ ^[A-Za-z0-9_]+$ ]]; then
    die "refusing invalid DRILL_PG_DB='$DRILL_PG_DB' (want [A-Za-z0-9_]+)"
  fi
fi

command -v "$RESTIC" >/dev/null || die "restic not found: $RESTIC"
[ -r "$PASSWORD_FILE" ] || die "password file not readable: $PASSWORD_FILE"
if [ "$FULL_OFFSITE" = 1 ]; then
  command -v "$RCLONE" >/dev/null || die "FULL_OFFSITE=1 needs rclone: $RCLONE"
  [ -r "$RCLONE_CONFIG" ] || die "FULL_OFFSITE=1 needs an rclone config: $RCLONE_CONFIG"
fi

printf 'host: %s  dataset: %s  date: %s\n' "$(uname -n)" "$DATASET" "$(date -Is)"
printf 'repo: %s\npassword-file: %s (contents never printed)\n' "$REPO" "$PASSWORD_FILE"
printf 'source: %s\nstaging: %s\nrestore-root: %s\n' "$SOURCE" "$STAGING" "$RESTORE_ROOT"
printf 'full-offsite: %s  key-only: %s  pg-db: %s\n' "$FULL_OFFSITE" "$KEY_ONLY" "${DRILL_PG_DB:-none}"
"$RESTIC" version 2>/dev/null | head -1 || true

# Serialize with the backups before any repository or Proton access.
(umask 077; mkdir -p "$(dirname "$MEDIA_BACKUP_LOCK")"; : >>"$MEDIA_BACKUP_LOCK"; chmod 0600 "$MEDIA_BACKUP_LOCK")
exec 9>>"$MEDIA_BACKUP_LOCK"
if ! flock -n 9; then
  echo "waiting for lock $MEDIA_BACKUP_LOCK (a backup holds it)..."
  flock 9
  ok "lock acquired"
fi

RUN_DIR=$RESTORE_ROOT/$(date -u +%Y%m%dT%H%M%SZ)-$$
install -d -m 0700 "$RUN_DIR"
TMP=$RUN_DIR/tmp
install -d -m 0700 "$TMP"

# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() {
  rc=$?
  if [ "$pg_db_created" = 1 ] && [ "$KEEP" != 1 ] && [ "$fail" -eq 0 ]; then
    "${PG_RUN[@]}" dropdb --if-exists "$DRILL_PG_DB" >/dev/null 2>&1 || true
  fi
  if [ "$KEEP" = 1 ]; then
    printf 'kept %s\n' "$RUN_DIR"
  else
    rm -rf "$RUN_DIR"
  fi
  exit "$rc"
}
trap cleanup EXIT

RESTIC_CMD=("$RESTIC")

restic_at() {
  local repo=$1
  shift
  "${RESTIC_CMD[@]}" --repo "$repo" --password-file "$PASSWORD_FILE" "$@"
}

snapshot_id() {
  restic_at "$1" snapshots latest --json 2>/dev/null |
    grep -o '"id":"[0-9a-f]*"' | head -1 | cut -d'"' -f4 || true
}

snapshot_time() {
  restic_at "$1" snapshots latest --json 2>/dev/null |
    grep -o '"time":"[^"]*"' | head -1 | cut -d'"' -f4 || true
}

# ---------------------------------------------------------------------------
# Local phase: check, list the latest snapshot, restore and verify a sample.
# ---------------------------------------------------------------------------
step "local: restic check $REPO"
if restic_at "$REPO" check; then
  ok "local: restic check"
else
  bad "local: restic check failed"
fi

if ! restic_at "$REPO" snapshots latest >/dev/null 2>"$TMP/snapshots.err"; then
  cat "$TMP/snapshots.err" >&2 || true
  bad "local: cannot read snapshots from $REPO"
  echo "DRILL FAIL ($fail checks)"
  exit 1
fi
snap_id=$(snapshot_id "$REPO")
snap_time=$(snapshot_time "$REPO")
if [ -z "$snap_id" ]; then
  bad "local: no snapshot found in $REPO"
  echo "DRILL FAIL ($fail checks)"
  exit 1
fi

restic_at "$REPO" ls "$snap_id" >"$TMP/snapshot-ls" 2>"$TMP/ls.err" ||
  { cat "$TMP/ls.err" >&2 || true; bad "local: restic ls $snap_id failed"; }
file_count=$(grep -v '/$' "$TMP/snapshot-ls" | grep -c '^/' || true)
printf 'snapshot: %s\n' "$snap_id"
printf 'time:     %s\n' "${snap_time:-?}"
printf 'files:    %s\n' "$file_count"

# Samples: the staged dump (small and critical) plus spread-out source files.
SAMPLE_PATHS=()
if grep -Fxq "$PG_DUMP_PATH" "$TMP/snapshot-ls"; then
  SAMPLE_PATHS+=("$PG_DUMP_PATH")
fi
mapfile -t candidates < <(grep -F "$SOURCE/" "$TMP/snapshot-ls" | grep -v '/$' || true)
if [ "$SAMPLES" -gt 0 ] && [ "${#candidates[@]}" -gt 0 ]; then
  take=$SAMPLES
  [ "$take" -gt "${#candidates[@]}" ] && take=${#candidates[@]}
  stride=$(( ${#candidates[@]} / take ))
  [ "$stride" -lt 1 ] && stride=1
  picked=0
  for ((i = 0; i < ${#candidates[@]} && picked < take; i += stride)); do
    SAMPLE_PATHS+=("${candidates[i]}")
    picked=$((picked + 1))
  done
fi
if [ "${#SAMPLE_PATHS[@]}" -eq 0 ]; then
  bad "local: no files under $SOURCE/ in snapshot $snap_id"
else
  printf 'sample:   %s path(s)\n' "${#SAMPLE_PATHS[@]}"
  for p in "${SAMPLE_PATHS[@]}"; do printf '          %s\n' "$p"; done
fi

# restore_and_verify <repo> <dest> <label> <snapshot>: restore only the sample
# with --include, then compare each restored file with `restic dump` of the
# same snapshot.
restore_and_verify() {
  local repo=$1 dest=$2 label=$3 snap=$4
  local -a restore_args=(restore "$snap" --target "$dest")
  local p expected actual src_hash
  for p in "${SAMPLE_PATHS[@]}"; do
    restore_args+=(--include "$p")
  done
  step "$label: restore $snap (${#SAMPLE_PATHS[@]} paths)"
  if ! restic_at "$repo" "${restore_args[@]}"; then
    bad "$label: restic restore failed"
    return 1
  fi
  for p in "${SAMPLE_PATHS[@]}"; do
    expected=
    actual=
    expected=$(restic_at "$repo" dump "$snap" "$p" 2>/dev/null | sha256sum | cut -d' ' -f1) || expected=
    actual=$(sha256sum "$dest$p" 2>/dev/null | cut -d' ' -f1) || actual=
    if [ -z "$expected" ] || [ -z "$actual" ]; then
      bad "$label: $p (could not read bytes)"
    elif [ "$expected" = "$actual" ]; then
      ok "$label: $p"
    else
      bad "$label: hash mismatch $p (snapshot=$expected restored=$actual)"
    fi
    if [ "$SOURCE_COMPARE" = 1 ] && [ -f "$SOURCE$p" ]; then
      src_hash=$(sha256sum "$SOURCE$p" 2>/dev/null | cut -d' ' -f1) || src_hash=
      if [ -n "$expected" ] && [ "$src_hash" = "$expected" ]; then
        ok "$label: source unchanged $p"
      else
        printf 'SKIP %s: source changed since the snapshot %s\n' "$label" "$p"
      fi
    fi
  done
}

restore_and_verify "$REPO" "$RUN_DIR/restore-local" "local" "$snap_id"

# ---------------------------------------------------------------------------
# Proton phase: copy the remote repo into a temp dir (remote is read-only
# here), check the copy, compare its latest snapshot, restore and verify.
# ---------------------------------------------------------------------------
if [ "$FULL_OFFSITE" = 1 ]; then
  proton_copy=${PROTON_COPY:-$RUN_DIR/proton-repo}
  install -d -m 0700 "$proton_copy"
  step "proton: rclone copy $PROTON_PATH -> $proton_copy (remote is read-only, stats every 30s)"
  if "$RCLONE" --config "$RCLONE_CONFIG" copy "$PROTON_PATH" "$proton_copy" \
    --timeout 5m --contimeout 30s --retries 5 --low-level-retries 20 --retries-sleep 10s \
    --transfers 8 --checkers 16 --stats 30s --stats-one-line --stats-log-level NOTICE; then
    ok "proton: copy complete"
    proton_snap=$(snapshot_id "$proton_copy")
    if [ -z "$proton_snap" ]; then
      bad "proton: the copy holds no snapshot"
    else
      if [ "$proton_snap" = "$snap_id" ]; then
        ok "proton: latest snapshot matches local ($proton_snap)"
      else
        bad "proton: copy latest ($proton_snap) differs from local ($snap_id)"
      fi
      if restic_at "$proton_copy" check; then
        ok "proton: restic check on the copy"
      else
        bad "proton: restic check on the copy failed"
      fi
      restore_and_verify "$proton_copy" "$RUN_DIR/restore-proton" "proton" "$proton_snap"
    fi
  else
    bad "proton: rclone copy failed"
  fi
fi

# ---------------------------------------------------------------------------
# Key-only phase: the escrow drill. Fresh HOME and cache, no RESTIC_* env, only
# the password file and the repository (or the Proton copy) may be used.
# ---------------------------------------------------------------------------
if [ "$KEY_ONLY" = 1 ]; then
  key_home=$RUN_DIR/keyonly/home
  key_cache=$RUN_DIR/keyonly/cache
  install -d -m 0700 "$key_home" "$key_cache"
  step "key-only: clean HOME=$key_home cache=$key_cache"
  RESTIC_CMD=(
    env -i
    PATH="$PATH"
    HOME="$key_home"
    XDG_CONFIG_HOME="$key_home/.config"
    RESTIC_CACHE_DIR="$key_cache"
    "$(command -v "$RESTIC")"
    --cache-dir "$key_cache"
  )
  if restic_at "$REPO" check; then
    ok "key-only: local check with the password file alone"
  else
    bad "key-only: local check failed"
  fi
  restore_and_verify "$REPO" "$RUN_DIR/restore-key-local" "key-only-local" "$snap_id"
  if [ -n "$proton_copy" ] && [ -d "$proton_copy" ]; then
    key_snap=$(snapshot_id "$proton_copy")
    if [ -n "$key_snap" ]; then
      restore_and_verify "$proton_copy" "$RUN_DIR/restore-key-proton" "key-only-proton" "$key_snap"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Postgres phase: stream the staged plain-SQL dump out of the snapshot into a
# scratch database. This is Immich's documented restore shape: gunzip, rewrite
# the emptied search_path back to "public, pg_catalog", psql in one transaction
# with ON_ERROR_STOP. The live `immich` database is never touched.
# ---------------------------------------------------------------------------
if [ "$(id -u)" = 0 ] && command -v runuser >/dev/null 2>&1 && id postgres >/dev/null 2>&1; then
  PG_RUN=(runuser -u postgres --)
fi
PG_PSQL=("${PG_RUN[@]}" psql --dbname="$DRILL_PG_DB" --single-transaction --set ON_ERROR_STOP=on)

if [ -n "$DRILL_PG_DB" ]; then
  step "postgres: restore $PG_DUMP_PATH into scratch database $DRILL_PG_DB"
  if ! command -v psql >/dev/null 2>&1; then
    warn "postgres: psql not available; skipping the requested PG phase"
    pg_skipped=1
  elif ! "${PG_RUN[@]}" psql -tAc 'select 1' >/dev/null 2>&1; then
    warn "postgres: no reachable database; skipping the requested PG phase"
    pg_skipped=1
  elif ! grep -Fxq "$PG_DUMP_PATH" "$TMP/snapshot-ls"; then
    bad "postgres: $PG_DUMP_PATH not in snapshot $snap_id"
  else
    existing=$("${PG_RUN[@]}" psql -d postgres -tAc \
      "select 1 from pg_database where datname = '$DRILL_PG_DB'" 2>/dev/null || true)
    if [ "$existing" = 1 ]; then
      case $DRILL_PG_DB in
        *_drill)
          "${PG_RUN[@]}" dropdb --if-exists "$DRILL_PG_DB" || bad "postgres: could not drop old scratch DB"
          ;;
        *)
          die "refusing: database '$DRILL_PG_DB' exists and is not a *_drill scratch DB"
          ;;
      esac
    fi
    if "${PG_RUN[@]}" createdb "$DRILL_PG_DB"; then
      pg_db_created=1
      ok "postgres: created scratch database $DRILL_PG_DB"
      step "postgres: restic dump | gunzip | search_path rewrite | psql"
      if restic_at "$REPO" dump "$snap_id" "$PG_DUMP_PATH" |
        gzip -dc |
        sed -e "s/SELECT pg_catalog.set_config('search_path', '', false);/SELECT pg_catalog.set_config('search_path', 'public, pg_catalog', true);/g" |
        "${PG_PSQL[@]}"; then
        ok "postgres: dump restored"
        tables=$("${PG_RUN[@]}" psql -d "$DRILL_PG_DB" -tAc \
          "select count(*) from information_schema.tables where table_schema = 'public'" 2>/dev/null || true)
        if [ -n "$tables" ] && [ "$tables" -gt 0 ] 2>/dev/null; then
          ok "postgres: $tables table(s) in public"
        else
          bad "postgres: restored database has no tables"
        fi
        assets=$("${PG_RUN[@]}" psql -d "$DRILL_PG_DB" -tAc \
          'select count(*) from asset' 2>/dev/null || true)
        if [ -n "$assets" ]; then
          printf 'INFO postgres: asset rows=%s (informational)\n' "$assets"
        fi
      else
        bad "postgres: psql restore failed"
      fi
    else
      bad "postgres: could not create scratch database $DRILL_PG_DB"
    fi
  fi
  if [ "$pg_db_created" = 1 ] && [ "$fail" -gt 0 ]; then
    printf 'INFO postgres: kept scratch database %s for inspection (drop with: dropdb %s)\n' \
      "$DRILL_PG_DB" "$DRILL_PG_DB"
  fi
fi

if [ "$fail" -eq 0 ]; then
  if [ "$pg_skipped" = 1 ]; then
    echo "DRILL SKIP ($fail failures; requested Postgres phase skipped: psql or database unavailable)"
    exit 2
  fi
  echo "DRILL PASS"
  exit 0
fi
echo "DRILL FAIL ($fail checks)"
exit 1
