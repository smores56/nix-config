#!/usr/bin/env bash
# Exercise drills/restic-restore-drill.sh against a temporary source tree, a
# temporary restic repository and a local rclone remote standing in for Proton.
# No root, no network, no /var/backup: every path and the host lock live under
# the temp dir.
#
# Usage: bash tests/restic_restore_drill.sh <path-to-restic-restore-drill.sh>
set -euo pipefail

drill=${1:?usage: restic_restore_drill.sh <drill script>}
[ -f "$drill" ] || {
  echo "drill script not found: $drill" >&2
  exit 1
}

tmp=$(mktemp -d)
pg_fixture_db=
cleanup() {
  if [ -n "$pg_fixture_db" ]; then
    psql -d postgres -tAc "drop database if exists \"$pg_fixture_db\"" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

export HOME="$tmp/home"
mkdir -p "$HOME" "$tmp/src/sub" "$tmp/staging" "$tmp/proton-host"

# A small tree with a nested file, a name with spaces, and enough files that
# the drill's stride sampling picks more than one.
for i in 1 2 3 4 5 6; do
  printf 'content-%s\n' "$i" >"$tmp/src/file$i.txt"
done
printf 'nested\n' >"$tmp/src/sub/nested file.txt"
printf 'select 1;\n' | gzip >"$tmp/staging/immich.sql.gz"
echo test-password >"$tmp/pw"

repo=$tmp/repo
pw=$tmp/pw
restic -r "$repo" --password-file "$pw" init >/dev/null
restic -r "$repo" --password-file "$pw" backup "$tmp/src" "$tmp/staging" --tag photos >/dev/null

# Change the source after the snapshot: the drill must compare against the
# snapshot, not the live tree, so it still has to pass.
printf 'changed-after-snapshot\n' >"$tmp/src/file2.txt"
printf 'new-after-snapshot\n' >"$tmp/src/file7.txt"
restic -r "$repo" --password-file "$pw" backup "$tmp/src" "$tmp/staging" --tag photos >/dev/null
printf 'changed-again\n' >"$tmp/src/file3.txt"

# Local rclone remote named `proton` whose root is a temp dir.
printf '[proton]\ntype = alias\nremote = %s/proton-host\n' "$tmp" >"$tmp/rclone.conf"
rclone --config "$tmp/rclone.conf" copy "$repo" proton:restic/Photos >/dev/null

run_drill() {
  env \
    MEDIA_BACKUP_LOCK="$tmp/lock" \
    DATASET=Photos \
    REPO="$repo" \
    PASSWORD_FILE="$pw" \
    SOURCE="$tmp/src" \
    STAGING="$tmp/staging" \
    RESTORE_ROOT="$tmp/restore-root" \
    RCLONE_CONFIG="$tmp/rclone.conf" \
    PROTON_PATH=proton:restic/Photos \
    SAMPLES=3 \
    "$@" \
    bash "$drill"
}

hash() { sha256sum "$1" | cut -d' ' -f1; }

# 1. Local phase only.
local_out=$(run_drill 2>&1) || {
  printf '%s\n' "$local_out" >&2
  echo "local drill failed" >&2
  exit 1
}
printf '%s\n' "$local_out" | grep -q 'DRILL PASS' || {
  printf '%s\n' "$local_out" >&2
  echo "local drill did not pass" >&2
  exit 1
}
printf '%s\n' "$local_out" | grep -q '^snapshot: ' || {
  echo "local drill did not report the snapshot id" >&2
  exit 1
}
printf '%s\n' "$local_out" | grep -q 'OK   local: ' || {
  echo "local drill did not report per-file verification" >&2
  exit 1
}
# The password must never reach the log.
if printf '%s\n' "$local_out" | grep -q 'test-password'; then
  echo "password leaked into the drill output" >&2
  exit 1
fi
if find "$tmp" -name 'BACKUP-LAST-SUCCESS' | grep -q .; then
  echo "drill wrote BACKUP-LAST-SUCCESS" >&2
  exit 1
fi

# 2. Proton copy and key-only escrow phases in one run.
offsite_out=$(run_drill FULL_OFFSITE=1 KEY_ONLY=1 2>&1) || {
  printf '%s\n' "$offsite_out" >&2
  echo "offsite/key-only drill failed" >&2
  exit 1
}
printf '%s\n' "$offsite_out" | grep -q 'DRILL PASS' || {
  printf '%s\n' "$offsite_out" >&2
  echo "offsite/key-only drill did not pass" >&2
  exit 1
}
printf '%s\n' "$offsite_out" | grep -q 'OK   proton: ' || {
  echo "drill did not verify the Proton copy" >&2
  exit 1
}
printf '%s\n' "$offsite_out" | grep -q 'OK   key-only-local: ' || {
  echo "drill did not verify a clean-home restore" >&2
  exit 1
}
printf '%s\n' "$offsite_out" | grep -q 'OK   key-only-proton: ' || {
  echo "drill did not verify a clean-home restore from the copy" >&2
  exit 1
}

# 3. The staged dump rides in the snapshot byte-for-byte.
dump_hash=$(hash "$tmp/staging/immich.sql.gz")
dump_restored=$(restic -r "$repo" --password-file "$pw" dump latest "$tmp/staging/immich.sql.gz" | sha256sum | cut -d' ' -f1)
if [ "$dump_hash" != "$dump_restored" ]; then
  echo "staged dump is not present in the snapshot" >&2
  exit 1
fi

# 4. The live database name is refused before any work happens.
set +e
run_drill DRILL_PG_DB=immich >"$tmp/refuse.log" 2>&1
refuse_rc=$?
set -e
if [ "$refuse_rc" -ne 2 ] || ! grep -q 'refusing DRILL_PG_DB=immich' "$tmp/refuse.log"; then
  echo "DRILL_PG_DB=immich was not refused (exit=$refuse_rc)" >&2
  cat "$tmp/refuse.log" >&2
  exit 1
fi

# 5. Postgres phase. Use a real server when this machine has one; otherwise
#    put psql/createdb/dropdb shims on PATH so the streaming pipeline, the
#    search_path rewrite and the scratch-database naming are still exercised.
pg_ran=0
if command -v psql >/dev/null 2>&1 &&
  command -v pg_dump >/dev/null 2>&1 &&
  psql -d postgres -tAc 'select 1' >/dev/null 2>&1; then
  pg_fixture_db=restic_drill_src_$$
  if psql -d postgres -v ON_ERROR_STOP=1 -tAc "create database \"$pg_fixture_db\"" >/dev/null 2>&1; then
    psql -d "$pg_fixture_db" -v ON_ERROR_STOP=1 -c \
      'create table drill_probe(id int); insert into drill_probe values (1);' >/dev/null
    pg_dump --clean --if-exists -d "$pg_fixture_db" | gzip >"$tmp/staging/immich.sql.gz"
    psql -d postgres -tAc "drop database \"$pg_fixture_db\"" >/dev/null
    pg_fixture_db=
    restic -r "$repo" --password-file "$pw" backup "$tmp/src" "$tmp/staging" --tag photos >/dev/null
    pg_out=$(run_drill DRILL_PG_DB=restic_drill_$$_drill 2>&1) || {
      printf '%s\n' "$pg_out" >&2
      echo "postgres drill failed" >&2
      exit 1
    }
    printf '%s\n' "$pg_out" | grep -q 'OK   postgres: dump restored' || {
      printf '%s\n' "$pg_out" >&2
      echo "postgres phase did not restore the dump" >&2
      exit 1
    }
    pg_ran=1
  fi
fi

if [ "$pg_ran" = 0 ]; then
  mkdir -p "$tmp/bin"
  bash_bin=$(command -v bash)
  write_shim() {
    { printf "#!%s\n" "$bash_bin"; cat; } >"$1"
    chmod +x "$1"
  }
  write_shim "$tmp/bin/psql" <<'EOS'
set -euo pipefail
sql=
while [ $# -gt 0 ]; do
  case $1 in
    -d | --dbname)
      shift 2
      ;;
    -tAc)
      sql=$2
      shift 2
      ;;
    -v | -c | --single-transaction | --set)
      shift 2
      ;;
    *) shift ;;
  esac
done
if [ -n "$sql" ]; then
  case $sql in
    'select 1') echo 1 ;;
    *pg_database*) : ;;
    *information_schema.tables*) echo 2 ;;
    *) : ;;
  esac
  exit 0
fi
cat >"$DRILL_SHIM_SQL_OUT"
EOS
  write_shim "$tmp/bin/createdb" <<'EOS'
printf 'createdb %s\n' "$*" >>"$DRILL_SHIM_DB_LOG"
EOS
  write_shim "$tmp/bin/dropdb" <<'EOS'
printf 'dropdb %s\n' "$*" >>"$DRILL_SHIM_DB_LOG"
EOS

  # Immich's documented plain-SQL shape, including the line the restore
  # rewrites, plus a table to prove the SQL reaches psql intact.
  {
    printf "SELECT pg_catalog.set_config('search_path', '', false);\n"
    printf 'CREATE TABLE drill_probe (id integer);\n'
    printf 'INSERT INTO drill_probe VALUES (1);\n'
  } | gzip >"$tmp/staging/immich.sql.gz"
  restic -r "$repo" --password-file "$pw" backup "$tmp/src" "$tmp/staging" --tag photos >/dev/null

  : >"$tmp/shim-sql"
  : >"$tmp/shim-db"
  pg_out=$(run_drill \
    PATH="$tmp/bin:$PATH" \
    DRILL_SHIM_SQL_OUT="$tmp/shim-sql" \
    DRILL_SHIM_DB_LOG="$tmp/shim-db" \
    DRILL_PG_DB=restic_drill_$$_drill 2>&1) || {
    printf '%s\n' "$pg_out" >&2
    echo "postgres drill (shim) failed" >&2
    exit 1
  }
  printf '%s\n' "$pg_out" | grep -q 'OK   postgres: dump restored' || {
    printf '%s\n' "$pg_out" >&2
    echo "postgres shim phase did not restore the dump" >&2
    exit 1
  }
  grep -q "set_config('search_path', 'public, pg_catalog', true)" "$tmp/shim-sql" || {
    echo "search_path rewrite missing from the streamed SQL" >&2
    exit 1
  }
  grep -q 'CREATE TABLE drill_probe' "$tmp/shim-sql" || {
    echo "dump body missing from the streamed SQL" >&2
    exit 1
  }
  grep -q "createdb restic_drill_$$_drill" "$tmp/shim-db" || {
    echo "drill did not create the caller-named scratch database" >&2
    cat "$tmp/shim-db" >&2
    exit 1
  }
fi

echo "restic_restore_drill.sh: ok"
