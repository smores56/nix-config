#!/usr/bin/env bash
# backup.sh -- generic plain-tree rclone 3-2-1 backup for one dataset.
#
# One copy of the data lives in a versioned local mirror (copy #2) on the backup
# disk, and -- when the dataset is offsite -- a second copy mirrors that mirror
# to the remote (copy #3). The source itself is copy #1.
#
# Nothing here ever deletes source data:
#
# * Every transport uses `rclone copy`, never `sync`. `sync` would propagate a
#   local deletion into the mirror; `copy` only ever adds or overwrites.
# * The local copy is versioned with `--backup-dir`: when a file changes, rclone
#   moves the previous revision under `versions/<date>` instead of clobbering it,
#   so overwritten and deleted files survive locally.
# * The offsite copy deliberately has no `--backup-dir`: versions stay local-only.
#   The remote is a plain append-only mirror -- stale files there are harmless and
#   are never pruned, so a lost local disk cannot take the offsite copy with it.
#
# Every mirror is verified with `rclone check --checksum --one-way`, scoped to the
# files the copy actually wrote this run (`--files-from0`) instead of the whole
# tree. Which pair is compared depends on the dataset: the offsite copy against
# the local mirror, or -- for a local-only dataset (`--offsite` absent) -- the
# source against the local mirror. When nothing changed the check is skipped and
# `--full-check` forces the whole-tree walk for a periodic integrity scan.
# rclone exits 0 even when it could not compare anything (e.g. a hash-less
# backend), so the "<n> hashes could not be checked" summary is parsed and any
# non-zero count is a hard failure: an unverified mirror is not a backup.
#
# Every rclone step is watched for stalled progress: a transfer that stops
# advancing its stats counters is killed and retried (the copy is resumable).
# rclone's own idle timeout does not catch a wedged upload session, which once
# hung a seed run for 18h while it held the shared Proton lock.
#
# The rclone config (holding the Proton credential) is read from a file at
# runtime, never passed on the command line (argv leaks to `ps`) and never baked
# into the Nix store.
#
# Deliberate losses versus the deleted Python driver: the stall watchdog samples
# the log every 30s instead of on every streamed line (rclone logs its counters
# every 30s anyway), and a partial line is only visible once newline-terminated.
set -uo pipefail
umask 077

# Host-wide run lock shared by every entry point (systemd timer, manual
# `backup`, seed runs). Serializing here stops two rclone clients blanking the
# single-use Proton refresh token (rclone#9880). Created 0600 in /run/lock.
LOCK_PATH=/run/lock/media-backup.lock
# rclone logs a stats block this often; the watchdog cannot observe progress at
# a finer cadence. BACKUP_STATS_INTERVAL is a test-only override: the Nix module
# still asserts a >=60s stallTimeout, which is twice the production cadence.
STATS_INTERVAL=${BACKUP_STATS_INTERVAL:-30}
# Wall-clock cap for a non-rclone step (e.g. the preBackup pg_dump) when the
# dataset sets none. Always applied, so stall-timeout 0 cannot leave a hung dump
# holding the lock forever.
DEFAULT_STEP_TIMEOUT=12h

# Proton Drive answers transient 404/422/502s under load. These make rclone back
# off and retry them instead of surfacing a failure, and cap how long any single
# connection may sit idle.
NET_FLAGS=(--timeout 5m --contimeout 30s --retries 5 --low-level-retries 20 --retries-sleep 10s)
# The stall watchdog reads the stats counters, which rclone logs at INFO -- hidden
# by the default NOTICE level -- so raise the stats-log level explicitly. The
# multi-line block (not --stats-one-line) is what keeps the counter labels.
STATS_FLAGS=(--stats "${STATS_INTERVAL}s" --stats-log-level NOTICE)
# Copy steps log one JSON object per line so the changed paths can be extracted;
# the stats counters live in a `msg` value the watchdog greps still match.
COPY_LOG_FLAGS=(--use-json-log --log-level INFO)

# rclone reports a content write with a message containing "Copied (" -- today
# "Copied (new)" / "Copied (replaced existing)", plus threaded variants. A
# metadata-only touch logs "Updated modification time in destination" instead,
# which must not enter the verify set. `msg` is always rclone's own operation
# string; a source filename only ever appears in `object`.
COPIED_MARKER='Copied ('

NAME=""
SOURCE=""
BACKUP_ROOT=""
REMOTE="proton"
RCLONE_CONFIG=""
OFFSITE=0
FULL_CHECK=0
DRY_RUN=0
NO_LOCK=0
PRE_BACKUP=""
STALL="30m"
STEP_TIMEOUT=$DEFAULT_STEP_TIMEOUT
DATE=$(date +%F)
EXCLUDES=()

usage() {
  cat >&2 <<'EOF'
usage: backup --name NAME --source DIR --backup-root DIR --rclone-config FILE
              [--remote NAME] [--offsite] [--pre-backup SCRIPT] [--exclude GLOB]...
              [--stall-timeout DUR] [--timeout DUR] [--date DATE]
              [--full-check] [--dry-run] [--no-lock]
EOF
  exit 2
}

die() {
  printf 'backup failed: %s\n' "$*" >&2
  exit 1
}

# Strip C0 control characters (except tab): rclone relays source filenames
# verbatim, so a crafted name can smuggle ANSI escapes into the journal or the
# failure marker.
sanitize() {
  [[ -n ${1:-} ]] && printf '%s' "$1" | tr -d '\000-\010\012-\037'
}

quote_args() {
  local out="" arg
  for arg in "$@"; do out+=$(printf '%q ' "$arg"); done
  printf '%s' "$out"
}

# Parse a compact duration ("90", "30m", "2h", "1d") into seconds.
parse_duration() {
  local text=$1
  [[ $text =~ ^([0-9]+)([smhd]?)$ ]] || return 1
  local n=$((10#${BASH_REMATCH[1]}))
  case ${BASH_REMATCH[2]} in
    "" | s) echo "$n" ;;
    m) echo $((n * 60)) ;;
    h) echo $((n * 3600)) ;;
    d) echo $((n * 86400)) ;;
  esac
}

while (($# > 0)); do
  case $1 in
    --name)
      NAME=${2:?}
      shift 2
      ;;
    --source)
      SOURCE=${2:?}
      shift 2
      ;;
    --backup-root)
      BACKUP_ROOT=${2:?}
      shift 2
      ;;
    --remote)
      REMOTE=${2:?}
      shift 2
      ;;
    --rclone-config)
      RCLONE_CONFIG=${2:?}
      shift 2
      ;;
    --offsite)
      OFFSITE=1
      shift
      ;;
    --pre-backup)
      PRE_BACKUP=${2:?}
      shift 2
      ;;
    --exclude)
      EXCLUDES+=("${2:?}")
      shift 2
      ;;
    --stall-timeout)
      STALL=${2:?}
      shift 2
      ;;
    --timeout)
      STEP_TIMEOUT=${2:?}
      shift 2
      ;;
    --date)
      DATE=${2:?}
      shift 2
      ;;
    --full-check)
      FULL_CHECK=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --no-lock)
      NO_LOCK=1
      shift
      ;;
    -h | --help) usage ;;
    *) usage ;;
  esac
done

[[ -n $NAME && -n $SOURCE && -n $BACKUP_ROOT && -n $RCLONE_CONFIG ]] || usage
# The name is a local path component and a remote folder, and the date becomes a
# version folder: both must be single tokens that cannot escape the backup tree.
[[ $NAME =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && $NAME != *..* ]] ||
  die "invalid --name '$NAME': letters, digits, dot, dash, underscore only"
[[ $DATE =~ ^[A-Za-z0-9_.-]+$ && $DATE != *..* && $DATE != "." ]] ||
  die "invalid --date '$DATE': a plain date/timestamp token"
STALL_SECONDS=$(parse_duration "$STALL") ||
  die "invalid --stall-timeout '$STALL': use <number><s|m|h|d> or 0"
((STALL_SECONDS == 0 || STALL_SECONDS >= 2 * STATS_INTERVAL)) ||
  die "stall-timeout ${STALL_SECONDS}s is below twice the rclone stats interval; pass 0 to disable"
TIMEOUT_SECONDS=$(parse_duration "$STEP_TIMEOUT") ||
  die "invalid --timeout '$STEP_TIMEOUT': use <number><s|m|h|d>"
if ((NO_LOCK)) && [[ ${BACKUP_ALLOW_NO_LOCK:-} != 1 ]]; then
  die "--no-lock requires BACKUP_ALLOW_NO_LOCK=1: bypassing the host-wide lock risks two rclone clients blanking the single-use Proton token"
fi

DATASET_DIR=$BACKUP_ROOT/$NAME
LOCAL=$DATASET_DIR/current
VERSIONS=$DATASET_DIR/versions
MARKER=$DATASET_DIR/BACKUP-FAILED
LAST_SUCCESS=$DATASET_DIR/BACKUP-LAST-SUCCESS
OFFSITE_TARGET=$REMOTE:$NAME

EXCLUDE_FLAGS=()
for pattern in ${EXCLUDES[@]+"${EXCLUDES[@]}"}; do EXCLUDE_FLAGS+=(--exclude "$pattern"); done

# Every run gets a private 0700 workspace. It holds the step logs (used for
# changed-path extraction) and the NUL-separated verify list; the trap removes
# it on a normal exit and after a failure.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/backup.XXXXXX") || die "cannot create a workspace"
trap 'rm -rf "$WORK"' EXIT

fail() {
  if ((DRY_RUN == 0)); then
    install -d -m 0700 "$DATASET_DIR" 2>/dev/null || true
    # Best-effort: never let a marker write mask the original failure.
    { sanitize "$*"; echo; } >"$MARKER" 2>/dev/null || true
  fi
  printf 'backup failed: %s\n' "$(sanitize "$*")" >&2
  exit 1
}

acquire_lock() {
  local path=$1
  exec 9>>"$path" || fail "cannot open lock $path"
  if ! flock -n 9; then
    # A silent multi-hour block is indistinguishable from a hang, so say so.
    echo "waiting for lock $path ..."
    flock 9 || fail "cannot acquire lock $path"
  fi
}

# A stalled run keeps printing stats whose counters do not advance, so only a new
# high-water mark on `Transferred:` or `Checks:` counts as progress.
progress_token() {
  local log=$1 transferred checks
  transferred=$(grep -aoE 'Transferred:[^"]*' "$log" 2>/dev/null | tail -n1)
  checks=$(grep -aoE 'Checks:[[:space:]]*[0-9]+' "$log" 2>/dev/null | tail -n1)
  printf '%s|%s' "$transferred" "$checks"
}

watchdog() {
  local pid=$1 log=$2 limit=$3 flag=$4
  local last="" elapsed=0 token
  while kill -0 "$pid" 2>/dev/null; do
    sleep "$STATS_INTERVAL"
    kill -0 "$pid" 2>/dev/null || return 0
    token=$(progress_token "$log")
    if [[ $token == "$last" ]]; then
      elapsed=$((elapsed + STATS_INTERVAL))
      if ((elapsed >= limit)); then
        printf '! no transfer progress for %ss; killing %s\n' "$limit" "$pid" >&2
        : >"$flag"
        kill -TERM "$pid" 2>/dev/null || true
        return 0
      fi
    else
      last=$token
      elapsed=0
    fi
  done
}

# run_step LABEL STALL_TIMEOUT LOG ATTEMPTS -- COMMAND...
# Relays output live, kills a stalled attempt, retries it, and fails the run on a
# non-stall error. Attempts are reused by every rclone step (copy is resumable).
run_step() {
  local label=$1 stall=$2 log=$3 attempts=$4
  shift 4
  [[ ${1:-} == -- ]] && shift
  local cmd attempt rc pid tail_pid watcher flag
  cmd=$(quote_args "$@")
  flag=$WORK/stalled
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    : >"$log"
    rm -f "$flag"
    printf '+ %s\n' "$cmd" >&2
    "$@" >"$log" 2>&1 &
    pid=$!
    # Relay the step log live, stripping C0 control characters (except tab) so a
    # crafted source filename cannot smuggle ANSI escapes into the journal.
    tail -n +1 -f --pid="$pid" "$log" 2>/dev/null | stdbuf -oL tr -d '\000-\010\013-\037' >&2 &
    tail_pid=$!
    watcher=""
    if ((stall > 0)); then
      watchdog "$pid" "$log" "$stall" "$flag" &
      watcher=$!
    fi
    rc=0
    wait "$pid" || rc=$?
    if [[ -n $watcher ]]; then
      kill "$watcher" 2>/dev/null || true
      wait "$watcher" 2>/dev/null || true
    fi
    wait "$tail_pid" 2>/dev/null || true
    if [[ -e $flag ]]; then
      if ((attempt < attempts)); then
        printf '! stalled, retry %d/%d: %s\n' "$attempt" "$((attempts - 1))" "$cmd" >&2
        continue
      fi
      fail "no transfer progress for ${stall}s: $cmd"
    fi
    ((rc == 0)) || fail "$label failed (exit $rc): $cmd"
    return 0
  done
}

# Paths this copy wrote, NUL-separated. `--files-from0` is exclusive with every
# other filter, and NUL keeps names with newlines or a leading `#`/`;` intact.
extract_paths() {
  jq -Rj --arg marker "$COPIED_MARKER" 'fromjson? | select(type == "object")
         | select((.msg? // "") | contains($marker))
         | select((.object? | type) == "string")
         | .object + "\u0000"' "$1"
}

# True when the copy's final stats block reports transferred bytes. A run that
# moved data but recorded no changed paths must not be skipped as "no changes".
# Only the tail is parsed: rclone's exit stats block is the last JSON line, and
# a seed log can be hundreds of megabytes.
moved_data() {
  local bytes
  bytes=$(tail -n 50 "$1" | jq -s '[.[] | objects | .stats.bytes? // empty] | last // 0' 2>/dev/null || echo 0)
  [[ $bytes =~ ^[0-9]+$ ]] && ((bytes > 0))
}

build_check() {
  # build_check SOURCE DEST [PATHS_FILE]
  CHECK=(rclone --config "$RCLONE_CONFIG" "${NET_FLAGS[@]}" "${STATS_FLAGS[@]}"
    check --checksum --one-way "$1" "$2")
  if [[ -n ${3:-} ]]; then
    CHECK+=(--files-from0 "$3")
  else
    # Excluded files never enter the mirror, so a whole-tree walk must apply the
    # same patterns; a scoped check names files the excludes never match.
    CHECK+=(${EXCLUDE_FLAGS[@]+"${EXCLUDE_FLAGS[@]}"})
  fi
}

# rclone exits 0 even when it compared nothing, so a zero (or missing) count
# means the changed paths were not actually verified.
assert_check_ok() {
  local label=$1 log=$2 unchecked checked
  unchecked=$(grep -oE '[0-9]+ hashes could not be checked' "$log" | tail -n1 | grep -oE '^[0-9]+' || true)
  if [[ -n $unchecked ]] && ((unchecked > 0)); then
    fail "$label check could not verify every file: $(tail -n 5 "$log")"
  fi
  checked=$(grep -oE 'Checks:[[:space:]]+[0-9]+' "$log" | grep -oE '[0-9]+$' | sort -n | tail -n1 || true)
  if [[ -z $checked ]] || ((checked == 0)); then
    fail "$label check verified no files; the changed paths were not compared (missing on the mirror, or an over-broad exclude?)"
  fi
}

# verify_mirror LABEL SOURCE DEST COPY_LOG
# Returns 0 when the mirror was verified this run and 1 when the check was
# skipped, so the caller never clears a prior failure's marker on a skip.
verify_mirror() {
  local label=$1 src=$2 dest=$3 copy_log=$4
  local check_log=$WORK/check.log paths=$WORK/paths
  if ((FULL_CHECK == 0)); then
    extract_paths "$copy_log" >"$paths"
    if [[ ! -s $paths ]]; then
      moved_data "$copy_log" &&
        fail "$label copy transferred data but no changed paths were recorded; refusing to skip verification"
      printf 'no %s changes; skipping verification\n' "$label"
      return 1
    fi
    build_check "$src" "$dest" "$paths"
  else
    build_check "$src" "$dest"
  fi
  run_step "$label check" "$STALL_SECONDS" "$check_log" 3 -- "${CHECK[@]}"
  assert_check_ok "$label" "$check_log"
  return 0
}

resolve_date() {
  local base=$1 candidate stamp serial=1
  if [[ ! -e $VERSIONS/$base ]]; then
    printf '%s' "$base"
    return
  fi
  # rclone's --backup-dir would otherwise overwrite a same-named file left by an
  # earlier run on the same day, silently dropping that version.
  stamp=$(date +%H%M%S)
  candidate="${base}T${stamp}"
  while [[ -e $VERSIONS/$candidate ]]; do
    candidate="${base}T${stamp}-${serial}"
    serial=$((serial + 1))
  done
  printf '%s' "$candidate"
}

require_source() {
  [[ -d $SOURCE ]] || fail "source '$SOURCE' is not a directory"
  # `copy` never deletes, so an empty source would leave the mirror empty and
  # `--one-way` would then pass trivially: a silent "backup succeeded" with
  # nothing in it.
  [[ -n $(find "$SOURCE" -mindepth 1 -maxdepth 1 -print -quit) ]] ||
    fail "source '$SOURCE' is empty; refusing to back up nothing"
}

run_backup() {
  DATE=$(resolve_date "$DATE")
  install -d -m 0700 "$LOCAL" "$VERSIONS/$DATE" || fail "cannot create $DATASET_DIR"

  # preBackup runs first, outside the host lock, and may *produce* the source (a
  # producer-style dataset starts empty), so the emptiness check must follow it.
  if [[ -n $PRE_BACKUP ]]; then
    printf '+ %s\n' "$PRE_BACKUP" >&2
    local rc=0
    if ((TIMEOUT_SECONDS > 0)); then
      BACKUP_DATE=$DATE BACKUP_CURRENT=$LOCAL BACKUP_SOURCE=$SOURCE \
        timeout --kill-after=30s "${TIMEOUT_SECONDS}s" "$PRE_BACKUP" || rc=$?
    else
      BACKUP_DATE=$DATE BACKUP_CURRENT=$LOCAL BACKUP_SOURCE=$SOURCE "$PRE_BACKUP" || rc=$?
    fi
    ((rc == 0)) || fail "preBackup failed (exit $rc): $PRE_BACKUP"
  fi

  require_source

  if ((NO_LOCK == 0)); then
    # Proton refresh tokens are single-use, so offsite datasets serialize on the
    # host-wide lock; a local-only dataset only needs to serialize with itself.
    if ((OFFSITE)); then
      acquire_lock "$LOCK_PATH"
    else
      acquire_lock "/run/lock/media-backup-${NAME}.lock"
    fi
  fi

  local local_log=$WORK/local.log offsite_log=$WORK/offsite.log
  local local_args=(--config "$RCLONE_CONFIG" "${NET_FLAGS[@]}" "${STATS_FLAGS[@]}")
  # With no offsite leg the local copy's log is the only record of what changed,
  # so it (and only it) emits JSON for the local check to scope against.
  ((OFFSITE)) || local_args+=("${COPY_LOG_FLAGS[@]}")
  local_args+=(copy "$SOURCE" "$LOCAL" --backup-dir "$VERSIONS/$DATE")
  local_args+=(${EXCLUDE_FLAGS[@]+"${EXCLUDE_FLAGS[@]}"})
  run_step "local copy" "$STALL_SECONDS" "$local_log" 3 -- rclone "${local_args[@]}"

  local verified=0
  if ((OFFSITE)); then
    # --protondrive-replace-existing-draft: a failed Proton upload leaves a
    # draft, and without this the retry dies with "a draft exist".
    run_step "offsite copy" "$STALL_SECONDS" "$offsite_log" 3 -- rclone \
      --config "$RCLONE_CONFIG" "${NET_FLAGS[@]}" "${STATS_FLAGS[@]}" "${COPY_LOG_FLAGS[@]}" \
      --protondrive-replace-existing-draft=true \
      copy "$LOCAL" "$OFFSITE_TARGET" \
      ${EXCLUDE_FLAGS[@]+"${EXCLUDE_FLAGS[@]}"}
    verify_mirror offsite "$LOCAL" "$OFFSITE_TARGET" "$offsite_log" && verified=1
  else
    verify_mirror local "$SOURCE" "$LOCAL" "$local_log" && verified=1
  fi

  # Clear the marker only when the mirror was actually verified this run: a
  # skipped check must not erase a prior failure's evidence.
  ((verified)) && rm -f "$MARKER"
  if ((verified)) || [[ ! -e $MARKER ]]; then
    # A skipped check is safe only when the copy moved nothing; a prior failure
    # marker still suppresses the success timestamp.
    date -u +%Y-%m-%dT%H:%M:%S+00:00 >"$LAST_SUCCESS" ||
      echo "backup: could not write last-success marker" >&2
  fi
  echo "backup complete"
}

print_dry_run() {
  local args
  [[ -n $PRE_BACKUP ]] && printf '+ %s\n' "$PRE_BACKUP"
  args=(rclone --config "$RCLONE_CONFIG" "${NET_FLAGS[@]}" "${STATS_FLAGS[@]}")
  ((OFFSITE)) || args+=("${COPY_LOG_FLAGS[@]}")
  args+=(copy "$SOURCE" "$LOCAL" --backup-dir "$VERSIONS/$DATE")
  args+=(${EXCLUDE_FLAGS[@]+"${EXCLUDE_FLAGS[@]}"})
  printf '+ %s\n' "$(quote_args "${args[@]}")"
  if ((OFFSITE)); then
    printf '+ %s\n' "$(quote_args rclone --config "$RCLONE_CONFIG" "${NET_FLAGS[@]}" \
      "${STATS_FLAGS[@]}" "${COPY_LOG_FLAGS[@]}" --protondrive-replace-existing-draft=true \
      copy "$LOCAL" "$OFFSITE_TARGET" ${EXCLUDE_FLAGS[@]+"${EXCLUDE_FLAGS[@]}"})"
    build_check "$LOCAL" "$OFFSITE_TARGET"
  else
    build_check "$SOURCE" "$LOCAL"
  fi
  printf '+ %s\n' "$(quote_args "${CHECK[@]}")"
}

if ((DRY_RUN)); then
  print_dry_run
  exit 0
fi

run_backup
