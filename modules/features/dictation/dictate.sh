# shellcheck shell=bash
# `dictate toggle` — live dictation into the focused window.
#
# Streams committed speech segments into the focused window as they are
# recognised, so they stay editable in place. Raw by design; restructure
# afterwards with `md-structure`.
#
# Rendering happens in sherpa-onnx's Display class: while a segment is in
# progress it redraws stderr with ANSI clear-line escapes and carriage returns,
# and it only moves to a new numbered segment at an endpoint. Its own log
# chatter shares that stderr stream, newline-terminated. So the committed text
# of a segment is the last revision printed for its id, and the parser below has
# to strip escapes by hand and treat `\n` and `\r` alike as revision ends.

model_dir="@MODEL_DIR@"
alsa_plugin_dir="@ALSA_PLUGIN_DIR@"

device="${DICTATE_DEVICE:-default}"

# Endpoints fire on ~2.4s of trailing silence. Without forcing rule3 as well, a
# seamless ramble would only commit text every 20s (its default), so nothing
# would reach the buffer while thinking aloud.
segment_seconds="${DICTATE_SEGMENT_SECONDS:-8}"

# XDG_RUNTIME_DIR is per-user, 0700, and cleared on logout. Refuse the /tmp
# fallback: state files there are plantable by any local user, and we read the
# pid back out of one of them.
runtime_dir="${XDG_RUNTIME_DIR:?dictate: XDG_RUNTIME_DIR is not set}"
state_dir="$runtime_dir/dictate"
lock_file="$state_dir/lock"
pid_file="$state_dir/recorder.pid"
stamp_file="$state_dir/stamp"
fifo="$state_dir/stream.fifo"

debounce_ms=300

owner=0
recorder_pid=""
parser_pid=""

# wtype needs no daemon and works on niri today; ydotool goes through
# /dev/uinput and survives compositor virtual-keyboard regressions. Both read
# the transcript from stdin: argv is world-readable via /proc, and stdin also
# keeps ydotool's escape handling off (its argv default would turn `\n` into
# Enter), matching wtype.
type_text() {
  local text="$1"
  [[ -n "${text//[[:space:]]/}" ]] || return 0
  printf '%s' "$text" | wtype - 2>/dev/null && return 0
  printf '%s' "$text" | ydotool type --key-delay 0 --key-hold 0 -f - 2>/dev/null || true
}

stream_segments() {
  local segment_id="" segment_text="" revision="" char=

  # Vars are reached through bash's dynamic scope; no other caller exists.
  handle_revision() {
    local rev="$1"
    if [[ "$rev" =~ ^([0-9]+):(.*)$ ]]; then
      local id="${BASH_REMATCH[1]}"
      if [[ -n "$segment_id" && "$id" != "$segment_id" ]]; then
        type_text "$segment_text "
      fi
      segment_id="$id"
      segment_text="${BASH_REMATCH[2]}"
    elif [[ -n "$segment_id" && "$rev" == " "* ]]; then
      # Continuation of a wrapped segment.
      segment_text+="$rev"
    elif [[ -n "$rev" && -n "${DICTATE_DEBUG:-}" ]]; then
      printf '%s\n' "$rev" >&2
    fi
  }

  # `-N` (not `-n`) so a newline surfaces as a character; `-n` consumes it as a
  # delimiter and reports an empty string, which would fuse a log line into the
  # next revision and type it into the window.
  while IFS= read -r -N 1 char; do
    case "$char" in
      $'\n' | $'\r')
        handle_revision "$revision"
        revision=""
        ;;
      $'\033')
        # Consume the rest of the escape sequence (clear line, cursor up).
        while IFS= read -r -N 1 char; do
          [[ "$char" =~ [A-Za-z] ]] && break
        done
        ;;
      *) revision+="$char" ;;
    esac
  done
  handle_revision "$revision"
  type_text "$segment_text "
}

recorder_alive() {
  local pid
  pid="$(<"$pid_file" 2>/dev/null)" || return 1
  # A stale file can hold a reused pid, or a negative value that would turn
  # `kill` into a process-group broadcast.
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null
}

spawn_recorder() {
  # The fifo may be left over from a session that was killed before it could
  # clean up; unlink it so mkfifo owns a fresh inode.
  rm -f "$fifo"
  mkfifo -m 600 "$fifo"

  stream_segments < "$fifo" &
  parser_pid=$!

  ALSA_PLUGIN_DIR="$alsa_plugin_dir" sherpa-onnx-alsa \
    --tokens="$model_dir/tokens.txt" \
    --encoder="$model_dir/encoder.int8.onnx" \
    --decoder="$model_dir/decoder.int8.onnx" \
    --joiner="$model_dir/joiner.int8.onnx" \
    --rule3-min-utterance-length="$segment_seconds" \
    "$device" 2>"$fifo" &
  recorder_pid=$!

  owner=1
  printf '%s\n' "$recorder_pid" > "$pid_file"
}

cleanup() {
  [[ "$owner" == 1 ]] || return 0
  [[ -n "$recorder_pid" ]] && kill "$recorder_pid" 2>/dev/null || true
  rm -f "$pid_file" "$fifo"
}
trap cleanup EXIT

toggle() {
  install -d -m 700 "$state_dir"
  # Serialise the decision: without the lock two near-simultaneous presses both
  # pass the debounce and spawn two recorders splitting one fifo between them.
  exec 9>"$lock_file"
  flock 9

  local now last
  now="$(date +%s%N)"
  last="$(cat "$stamp_file" 2>/dev/null || echo 0)"
  if (( (now - last) / 1000000 < debounce_ms )); then
    return 0
  fi
  printf '%s\n' "$now" > "$stamp_file"

  if recorder_alive; then
    kill -INT "$(<"$pid_file")" 2>/dev/null || true
    return 0
  fi

  spawn_recorder
  # Release before blocking: the process that stops us must be able to take the
  # lock while this one waits out the session.
  exec 9>&-
  # Stopping kills the recorder; the parser then sees EOF and flushes the
  # in-progress segment rather than dropping the last thing said.
  wait "$recorder_pid" || true
  wait "$parser_pid" || true
}

case "${1:-toggle}" in
  toggle) toggle ;;
  *)
    printf 'usage: dictate toggle\n' >&2
    exit 2
    ;;
esac
