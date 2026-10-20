#!/usr/bin/env bash
# backup_watch.sh --source DIR --queue-dir DIR [--running-file FILE]
#                 --debounce-seconds N [--ignore PATTERN]...
#
# Recursive inotify watcher for a backup dataset. Changes are debounced into
# one request file per quiet batch; the backup unit drains the queue and a
# systemd DirectoryNotEmpty= path unit starts it. If a run is active (the
# running file exists), a batch is written as one follow-up request instead.
#
# Replaces modules/features/backup/backup_watch.py for restic datasets while
# the rclone datasets keep the Python watcher until T13. The ignore rules and
# queue semantics are deliberately identical, so the two cannot diverge in
# what counts as a change.
set -uo pipefail
umask 077

usage() {
  echo "usage: $0 --source DIR --queue-dir DIR --debounce-seconds N [--running-file FILE] [--ignore PATTERN]..." >&2
  exit 2
}

SOURCE=""
QUEUE_DIR=""
RUNNING_FILE=""
DEBOUNCE=""
IGNORES=()

while (($# > 0)); do
  case $1 in
    --source)
      SOURCE=${2:?}
      shift 2
      ;;
    --queue-dir)
      QUEUE_DIR=${2:?}
      shift 2
      ;;
    --running-file)
      RUNNING_FILE=${2:?}
      shift 2
      ;;
    --debounce-seconds)
      DEBOUNCE=${2:?}
      shift 2
      ;;
    --ignore)
      IGNORES+=("${2:?}")
      shift 2
      ;;
    -h | --help) usage ;;
    *)
      echo "unknown argument: $1" >&2
      usage
      ;;
  esac
done

[[ -n $SOURCE && -n $QUEUE_DIR && -n $DEBOUNCE ]] || usage
[[ $DEBOUNCE =~ ^[0-9]+$ ]] || {
  echo "debounce must be whole seconds, got \"$DEBOUNCE\"" >&2
  exit 2
}
SOURCE=$(cd "$SOURCE" && pwd) || {
  echo "source is not a directory: $SOURCE" >&2
  exit 2
}
mkdir -p "$QUEUE_DIR"

declare -A CHANGED=()
INOTIFY_PID=""

log() { printf '%s watch: %s\n' "$(date -Is)" "$*" >&2; }

# shellcheck disable=SC2329  # invoked through trap
cleanup() {
  if [[ -n $INOTIFY_PID ]]; then
    kill "$INOTIFY_PID" 2>/dev/null
    wait "$INOTIFY_PID" 2>/dev/null
  fi
}
# shellcheck disable=SC2329  # invoked through trap
stop() {
  cleanup
  exit 0
}
trap cleanup EXIT
trap stop INT TERM

# True when the path should not count as a change. Mirrors
# backup_watch.py:is_ignored -- hidden components, writer scratch names, and
# per-dataset globs matched against each component.
ignored() {
  local path=$1 rel parts part
  rel=${path#"$SOURCE"/}
  # Outside the source, or a lexical escape (../ handling).
  [[ $rel == "$path" ]] && return 0
  [[ $rel == ".." || $rel == ../* ]] && return 0
  IFS=/ read -ra parts <<<"$rel"
  for part in "${parts[@]}"; do
    [[ $part == .* ]] && return 0
    case $part in
      Thumbs.db | desktop.ini) return 0 ;;
      *.part | *.partial | *.tmp | *.temp | *.swp | *.swo | *.crdownload | *.download | *.aria2 | *.qB | *.!qB) return 0 ;;
    esac
    local pattern
    for pattern in "${IGNORES[@]}"; do
      # shellcheck disable=SC2053  # the pattern is a glob on purpose
      [[ $part == $pattern ]] && return 0
    done
  done
  return 1
}

flush() {
  ((${#CHANGED[@]} == 0)) && return 0
  local ts file kind
  ts=$(date +%Y%m%dT%H%M%S%N)
  if [[ -n $RUNNING_FILE && -e $RUNNING_FILE ]]; then
    file=$QUEUE_DIR/followup-$ts.req
    kind=followup
  else
    file=$QUEUE_DIR/$ts.queue
    kind=queue
  fi
  printf '%s\n' "${!CHANGED[@]}" | sort >"$file.tmp" &&
    chmod 0600 "$file.tmp" &&
    mv "$file.tmp" "$file"
  log "flushed $kind ${#CHANGED[@]} path(s) -> ${file##*/}"
  CHANGED=()
}

exec 3< <(inotifywait -m -r -q \
  -e modify,create,delete,move,attrib \
  --format '%e|%w%f' -- "$SOURCE")
INOTIFY_PID=$!
log "watching $SOURCE (debounce ${DEBOUNCE}s)"

pending=0
while true; do
  if ((!pending)); then
    IFS='|' read -r -u 3 ev path || break
    pending=1
  else
    IFS='|' read -r -t "$DEBOUNCE" -u 3 ev path
    rc=$?
    if ((rc != 0)); then
      flush
      ((rc > 128)) || break # >128 is the quiet-window timeout, else EOF
      pending=0
      continue
    fi
  fi

  # inotify queue overflow reports no path; queue one run rather than lose it.
  if [[ $ev == *Q_OVERFLOW* ]]; then
    CHANGED["$SOURCE"]=1
    log "inotify queue overflow"
    continue
  fi
  [[ -z ${path:-} ]] && continue
  if ignored "$path"; then
    log "ignored ${path#"$SOURCE"/} ($ev)"
    continue
  fi
  CHANGED[$path]=1
  log "queued ${path#"$SOURCE"/} ($ev)"
done

flush
# The unit restarts us; a nonzero exit makes that visible in the journal.
exit 1
