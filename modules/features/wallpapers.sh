# Wallpaper sync/selection body; wallpapers.nix substitutes @PLATFORM@,
# @SOURCE@ and @CACHE@ and wraps this with errexit/nounset/pipefail.

platform=@PLATFORM@
source_url=@SOURCE@
cache=@CACHE@
dest="$cache/Wallpapers"
state="$cache/state"

log() { printf 'wallpapers: %s\n' "$*" >&2; }

bucket_of() {
  if [ -z "${1:-}" ] || [ -z "${2:-}" ]; then
    return 1
  fi
  case "$1$2" in
    *[!0-9]*) return 1 ;;
  esac
  if [ "$1" -le 0 ] || [ "$2" -le 0 ]; then
    return 1
  fi
  # 16:9 (1.78) is standard, 21:9 (2.33) and wider are ultrawide; 2.0 splits
  # them without a tolerance.
  if awk -v w="$1" -v h="$2" 'BEGIN { exit !(w / h >= 2.0) }'; then
    printf 'Ultrawide\n'
  else
    printf 'Standard\n'
  fi
}

classify() {
  if [ "$#" -ne 2 ]; then
    log "usage: wallpapers classify <width> <height>"
    exit 2
  fi
  if ! bucket_of "$1" "$2"; then
    log "not a pixel size: $1 x $2"
    exit 2
  fi
}

# Rotation is random without replacement: a bucket keeps a shuffled queue of the
# images it has not shown yet, so a cycle repeats nothing until it runs dry.
# Entries that left the bucket are dropped from the queue. <used> carries the
# images already shown earlier in this run, so a queue drained mid-run cannot
# hand a second display of the same aspect an image the first one already has.
next_pick() {
  if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    log "usage: wallpapers pick <list> <queue> [<used>]"
    exit 2
  fi
  list=$1
  queue=$2
  used=${3:-}
  local -a all=() queued=() rest=() candidates=()
  local file picked=''
  mapfile -d '' -t all <"$list" 2>/dev/null || true
  if [ "${#all[@]}" -eq 0 ]; then
    log "no wallpapers in $list"
    return 1
  fi
  declare -A present=()
  for file in "${all[@]}"; do
    present["$file"]=1
  done
  declare -A shown=()
  if [ -n "$used" ] && [ -s "$used" ]; then
    mapfile -d '' -t queued <"$used" 2>/dev/null || true
    for file in "${queued[@]}"; do
      shown["$file"]=1
    done
  fi
  if [ -s "$queue" ]; then
    mapfile -d '' -t queued <"$queue" 2>/dev/null || true
    for file in "${queued[@]}"; do
      [ -n "${present[$file]:-}" ] || continue
      if [ -z "$picked" ]; then
        picked=$file
      else
        rest+=("$file")
      fi
    done
  fi
  if [ -z "$picked" ]; then
    for file in "${all[@]}"; do
      [ -z "${shown[$file]:-}" ] || continue
      candidates+=("$file")
    done
    # Every image of the aspect is already on screen this run; reuse is the
    # only option left.
    if [ "${#candidates[@]}" -eq 0 ]; then
      candidates=("${all[@]}")
    fi
    mapfile -d '' -t queued < <(printf '%s\0' "${candidates[@]}" | shuf -z) || true
    if [ "${#queued[@]}" -eq 0 ]; then
      log "could not shuffle $list"
      return 1
    fi
    picked=${queued[0]}
    rest=("${queued[@]:1}")
  fi
  if [ -d "$queue" ]; then
    log "$queue is a directory"
    return 1
  fi
  # A temp file plus rename keeps a torn write from losing the cycle, and
  # printf with no arguments would still write one empty record.
  if [ "${#rest[@]}" -gt 0 ]; then
    printf '%s\0' "${rest[@]}" >"$queue.new" || {
      log "cannot write $queue.new"
      return 1
    }
  else
    : >"$queue.new" || {
      log "cannot write $queue.new"
      return 1
    }
  fi
  mv "$queue.new" "$queue" || {
    log "cannot replace $queue"
    return 1
  }
  printf '%s\n' "$picked"
}

# A display that could not be set must not consume its image; put the pick back
# at the head so the next run offers it again. Callers only unpick what they
# have not recorded in <used>, so the second display of an aspect may still
# take it.
unpick() {
  queue=$1
  file=$2
  if ! printf '%s\0' "$file" >"$queue.new"; then
    log "cannot write $queue.new"
    return 1
  fi
  if [ -s "$queue" ] && ! cat "$queue" >>"$queue.new"; then
    log "cannot read $queue"
    return 1
  fi
  mv "$queue.new" "$queue" || {
    log "cannot replace $queue"
    return 1
  }
}
# The lock is taken at dispatch, before either the transfer or the scan, so on
# Linux a manual run cannot --delete underneath a timer run's classify pass.
# macOS has no flock here; launchd never double-starts the agent, and queue
# updates are a temp file plus rename, so only a manual run overlapping the
# agent can lose a pick.
lock() {
  if [ -L "$cache" ]; then
    log "$cache is a symlink; refusing to use it"
    exit 1
  fi
  mkdir -p "$cache" "$state"
  if [ "$platform" = linux ]; then
    exec 9>"$cache/.lock"
    if ! flock -n 9; then
      log "another run holds $cache/.lock; skipping"
      exit 0
    fi
  fi
}

sync_cache() {
  rsync_ssh=(-e 'ssh -o StrictHostKeyChecking=yes -o ConnectTimeout=20')
  # Bounds a stalled stream so it cannot wedge the launchd agent: launchd will
  # not start a second instance while this one runs. --timeout is the I/O
  # timeout; --contimeout would be a daemon-only flag that rsync rejects on the
  # ssh transport, so the connect bound lives in ssh's ConnectTimeout.
  #
  # An unmounted Proton tree is an empty directory on smortress, and --delete
  # would then erase the only cached set, so the listing is checked first.
  # A failed listing or transfer still reports failure so the timer does not
  # look green, but dispatch applies from the cache regardless: rotation has to
  # survive an outage. The probe's stderr is kept because ssh failures are
  # otherwise silent. Both bounds plus apply fit TimeoutStartSec=20min.
  probe_start=$SECONDS
  probe_err="$cache/.probe.err"
  if listing=$(timeout 240 rsync --list-only "${rsync_ssh[@]}" "$source_url" 2>"$probe_err"); then
    if [ -z "$listing" ]; then
      log "source listing is empty; keeping the cached set"
      return 1
    fi
  else
    status=$?
    log "listing failed (status $status, $((SECONDS - probe_start))s): $(head -c 300 "$probe_err" | tr '\n' ' ')"
    # A slow or flaky transport can starve the listing while a transfer still
    # works. Without a listing the deletes stay off, so this can only add files;
    # the run still reports the failure.
    if ! timeout 720 rsync -rt --no-owner --no-group \
      "${rsync_ssh[@]}" --timeout=120 "$source_url" "$dest/"; then
      log "transfer without deletes failed too"
    fi
    return 1
  fi
  # --delete-after so a transfer killed mid-flight leaves the old files in
  # place instead of a half-emptied cache.
  if ! timeout 780 rsync -rt --delete-after --no-owner --no-group \
    "${rsync_ssh[@]}" --timeout=120 "$source_url" "$dest/"; then
    log "transfer failed after $((SECONDS - probe_start))s"
    return 1
  fi
}

# Bucket the cached files by measured pixels, not by their folder: an image can
# be misfiled, and the display's mode is what decides. Per file, so identify's
# format escapes never matter.
classify_cache() {
  dir=$1
  out=$2
  if [ ! -d "$dir" ]; then
    log "no cached wallpapers at $dir yet"
    return 1
  fi
  : >"$out/Standard.list"
  : >"$out/Ultrawide.list"
  find "$dir" -type f -print0 | while IFS= read -r -d '' file; do
    case "$file" in
      *.jpg | *.jpeg | *.png | *.webp | *.jxl | *.JPG | *.JPEG | *.PNG | *.WEBP | *.JXL) ;;
      *) continue ;;
    esac
    case "$file" in
      *$'\n'* | *$'\t'*)
        # A control character would forge a log or read-back line; wallpapers
        # never legitimately have one.
        log "skipping $(printf '%q' "$file"): control character in name"
        continue
        ;;
    esac
    if [ "$platform" = darwin ]; then
      width=$(/usr/bin/sips -g pixelWidth "$file" 2>/dev/null | awk '/pixelWidth:/ { print $2; exit }')
      height=$(/usr/bin/sips -g pixelHeight "$file" 2>/dev/null | awk '/pixelHeight:/ { print $2; exit }')
    else
      dims=$(identify -ping -format '%w %h' "$file" 2>/dev/null) || continue
      width=${dims% *}
      height=${dims#* }
    fi
    if bucket=$(bucket_of "${width:-}" "${height:-}"); then
      printf '%s\0' "$file" >>"$out/$bucket.list"
    fi
  done
  LC_ALL=C sort -z -o "$out/Standard.list" "$out/Standard.list"
  LC_ALL=C sort -z -o "$out/Ultrawide.list" "$out/Ultrawide.list"
}

# Sets one image per display, drawing each from that aspect's queue.
apply_linux() {
  work=$1
  if ! outputs=$(niri msg --json outputs); then
    log "niri msg failed (is the session up?)"
    return 1
  fi
  printf '%s' "$outputs" | jq -r '
    to_entries[] | select(.value.current_mode != null) |
    "\(.key)\t\(.value.modes[.value.current_mode].width)\t\(.value.modes[.value.current_mode].height)"
  ' >"$work/displays"
  if [ ! -s "$work/displays" ]; then
    log "no active outputs"
    return 1
  fi
  set=0
  while IFS=$'\t' read -r connector width height; do
    if ! bucket=$(bucket_of "$width" "$height"); then
      log "$connector has an unusable mode ${width}x${height}; skipping"
      continue
    fi
    if ! picture=$(next_pick "$work/$bucket.list" "$state/queue-$bucket" "$work/used-$bucket"); then
      log "$connector has no $bucket images; leaving it unchanged"
      continue
    fi
    log "$connector ${width}x${height} -> $bucket $(basename "$picture")"
    if ! noctalia msg wallpaper-set "$connector" "$picture"; then
      log "noctalia rejected $connector"
      unpick "$state/queue-$bucket" "$picture"
      continue
    fi
    applied=$(noctalia msg wallpaper-get "$connector") || {
      unpick "$state/queue-$bucket" "$picture"
      continue
    }
    if [ "$applied" != "$picture" ]; then
      log "$connector reports '$applied' after setting '$picture'"
      unpick "$state/queue-$bucket" "$picture"
      continue
    fi
    # Recorded only now: a pick that failed to land may still be offered to the
    # next display of this aspect.
    printf '%s\0' "$picture" >>"$work/used-$bucket"
    set=$((set + 1))
  done <"$work/displays"
  if [ "$set" -eq 0 ]; then
    log "no display could be set"
    return 1
  fi
}

apply_macos() {
  work=$1
  /usr/sbin/system_profiler SPDisplaysDataType -json >"$work/displays.json" || return 1
  jq -r '
    [.SPDisplaysDataType[]?.spdisplays_ndrvs[]?
      | (._spdisplays_resolution // .spdisplays_resolution
         // ._spdisplays_pixelresolution // .spdisplays_pixelresolution)
      | select(. != null)
      | capture("(?<w>[0-9]+) ?x ?(?<h>[0-9]+)")
      | "\(.w)\t\(.h)"]
    | .[]' "$work/displays.json" >"$work/displays"
  if [ ! -s "$work/displays" ]; then
    log "no displays reported"
    return 1
  fi
  display_count=$(awk 'END { print NR }' "$work/displays")
  desktop_count=$(/usr/bin/osascript -e 'tell application "System Events" to count every desktop') || return 1
  # A display the profiler cannot describe would shift every later index and
  # put one display's rotation history on another; refuse rather than guess.
  if [ "$display_count" != "$desktop_count" ]; then
    log "system_profiler reports $display_count displays, System Events $desktop_count desktops; refusing to guess"
    return 1
  fi
  set=0
  : >"$work/expected"
  ordinal=0
  while IFS=$'\t' read -r width height; do
    ordinal=$((ordinal + 1))
    if ! bucket=$(bucket_of "$width" "$height"); then
      log "display $ordinal has an unusable resolution ${width}x${height}"
      printf '\n' >>"$work/expected"
      continue
    fi
    if ! picture=$(next_pick "$work/$bucket.list" "$state/queue-$bucket" "$work/used-$bucket"); then
      log "display $ordinal has no $bucket images; leaving it unchanged"
      printf '\n' >>"$work/expected"
      continue
    fi
    log "display $ordinal ${width}x${height} -> $bucket $(basename "$picture")"
    # NSWorkspace is broken on macOS 26+: setDesktopImageURL applies one image
    # to every display or silently keeps the old one. System Events still lands
    # per desktop; it needs Automation approval once.
    if ! /usr/bin/osascript - "$ordinal" "$picture" <<'APPLESCRIPT'
on run argv
  set idx to (item 1 of argv) as integer
  set picture_path to item 2 of argv
  tell application "System Events" to set picture of (item idx of (every desktop)) to picture_path
end run
APPLESCRIPT
    then
      log "could not set desktop $ordinal"
      unpick "$state/queue-$bucket" "$picture"
      printf '\n' >>"$work/expected"
      continue
    fi
    printf '%s\n' "$picture" >>"$work/expected"
    # Recorded only now: a pick that failed to land may still be offered to the
    # next display of this aspect.
    printf '%s\0' "$picture" >>"$work/used-$bucket"
    set=$((set + 1))
  done <"$work/displays"
  if [ "$set" -eq 0 ]; then
    log "no display could be set"
    return 1
  fi
  # Read back through the same System Events model used to set, one line per
  # desktop, so it lines up with `expected`.
  /usr/bin/osascript - "$desktop_count" <<'APPLESCRIPT' >"$work/applied"
on run argv
  set n to (item 1 of argv) as integer
  set out to ""
  tell application "System Events"
    repeat with i from 1 to n
      if i > 1 then set out to out & linefeed
      set out to out & (picture of desktop i)
    end repeat
  end tell
  return out
end run
APPLESCRIPT
  # Compare per desktop so a silent no-op names the desktop that kept its old
  # image instead of only failing the whole run.
  paste -d '\t' "$work/expected" "$work/applied" >"$work/readback"
  mismatch=0
  while IFS=$'\t' read -r want got; do
    if [ "$want" = "$got" ]; then continue; fi
    log "desktop read-back wants '$want', got '$got'"
    mismatch=1
  done <"$work/readback"
  if [ "$mismatch" -eq 1 ]; then
    log "wallpaper read-back does not match what was set"
    return 1
  fi
  # desktoppr reads through the NSWorkspace API macOS 26 broke; keep it as a
  # logged cross-check only.
  desktoppr 2>/dev/null | while IFS= read -r line; do log "desktoppr: $line"; done || true
}

apply() {
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  classify_cache "$dest" "$work"
  if [ "$platform" = darwin ]; then
    apply_macos "$work"
  else
    apply_linux "$work"
  fi
}

case "${1:-sync}" in
  sync)
    lock
    # Apply even when the sync failed: the cache is the client's source of
    # truth, but the failure still has to reach the unit status.
    status=0
    sync_cache || status=$?
    apply
    exit "$status"
    ;;
  apply)
    lock
    apply
    ;;
  classify)
    shift
    classify "$@"
    ;;
  pick)
    shift
    next_pick "$@"
    ;;
  unpick)
    shift
    unpick "$@"
    ;;
  buckets)
    shift
    if [ "$#" -ne 2 ]; then
      log "usage: wallpapers buckets <dir> <out>"
      exit 2
    fi
    classify_cache "$1" "$2"
    ;;
  *)
    log "usage: wallpapers [sync|apply|classify W H|pick LIST QUEUE [USED]|unpick QUEUE FILE|buckets DIR OUT]"
    exit 2
    ;;
esac
