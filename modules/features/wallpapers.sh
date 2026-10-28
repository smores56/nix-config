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

# Lists are NUL-delimited and the counter is digits-only, so neither a filename
# nor a marker can inject a record or bash arithmetic.
counter_of() {
  value=0
  if [ -s "$1" ]; then
    value=$(cat "$1")
    case "$value" in
      *[!0-9]* | '') value=0 ;;
    esac
    value=$((10#$value))
  fi
  printf '%s\n' "$value"
}

# One bucket counter shared by every display of that aspect; the display's rank
# within the run shifts the pick, so two same-aspect panels differ while a
# skipped display cannot permanently collapse their phase.
pick_at() {
  if [ "$#" -ne 3 ]; then
    log "usage: wallpapers pick-at <list> <counter> <rank>"
    exit 2
  fi
  list=$1
  counter=$2
  rank=$3
  case "$counter$rank" in
    *[!0-9]* | '') 
      log "not a counter/rank: $counter $rank"
      exit 2
      ;;
  esac
  files=()
  mapfile -d '' -t files <"$list" 2>/dev/null || true
  if [ "${#files[@]}" -eq 0 ]; then
    log "no wallpapers in $list"
    return 1
  fi
  count=${#files[@]}
  printf '%s\n' "${files[$(((10#$counter + 10#$rank) % count))]}"
}

# The lock is taken at dispatch, before either the transfer or the scan, so a
# manual run cannot --delete underneath a timer run's classify pass.
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
  # An unmounted Proton tree is an empty directory on smortress, and --delete
  # would then erase the only cached set. Refuse to sync an empty source.
  rsync_ssh=(-e 'ssh -o StrictHostKeyChecking=yes -o ConnectTimeout=20')
  if ! listing=$(timeout 120 rsync --list-only "${rsync_ssh[@]}" "$source_url" 2>/dev/null) ||
    [ -z "$listing" ]; then
    log "source is empty or unreachable; keeping the cached set"
    return 1
  fi
  # Bounded so a stalled stream cannot wedge the launchd agent: launchd will
  # not start a second instance while this one runs.
  timeout 1800 rsync -rt --delete --no-owner --no-group \
    "${rsync_ssh[@]}" --contimeout=20 --timeout=120 "$source_url" "$dest/"
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

# Sets one image per display and advances a bucket's counter only after a run
# that placed at least one image from it.
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
  counter_Standard=$(counter_of "$state/counter-Standard")
  counter_Ultrawide=$(counter_of "$state/counter-Ultrawide")
  rank_Standard=0
  rank_Ultrawide=0
  used_Standard=0
  used_Ultrawide=0
  set=0
  while IFS=$'\t' read -r connector width height; do
    if ! bucket=$(bucket_of "$width" "$height"); then
      log "$connector has an unusable mode ${width}x${height}; skipping"
      continue
    fi
    case "$bucket" in
      Standard)
        rank=$rank_Standard
        rank_Standard=$((rank_Standard + 1))
        counter=$counter_Standard
        ;;
      Ultrawide)
        rank=$rank_Ultrawide
        rank_Ultrawide=$((rank_Ultrawide + 1))
        counter=$counter_Ultrawide
        ;;
    esac
    if ! picture=$(pick_at "$work/$bucket.list" "$counter" "$rank"); then
      log "$connector has no $bucket images; leaving it unchanged"
      continue
    fi
    log "$connector ${width}x${height} -> $bucket $(basename "$picture")"
    if ! noctalia msg wallpaper-set "$connector" "$picture"; then
      log "noctalia rejected $connector"
      continue
    fi
    applied=$(noctalia msg wallpaper-get "$connector") || continue
    if [ "$applied" != "$picture" ]; then
      log "$connector reports '$applied' after setting '$picture'"
      continue
    fi
    case "$bucket" in
      Standard) used_Standard=1 ;;
      Ultrawide) used_Ultrawide=1 ;;
    esac
    set=$((set + 1))
  done <"$work/displays"
  if [ "$used_Standard" -eq 1 ]; then
    printf '%s\n' "$((counter_Standard + 1))" >"$state/counter-Standard"
  fi
  if [ "$used_Ultrawide" -eq 1 ]; then
    printf '%s\n' "$((counter_Ultrawide + 1))" >"$state/counter-Ultrawide"
  fi
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
  counter_Standard=$(counter_of "$state/counter-Standard")
  counter_Ultrawide=$(counter_of "$state/counter-Ultrawide")
  rank_Standard=0
  rank_Ultrawide=0
  used_Standard=0
  used_Ultrawide=0
  set=0
  : >"$work/expected"
  ordinal=0
  while IFS=$'\t' read -r width height; do
    ordinal=$((ordinal + 1))
    if ! bucket=$(bucket_of "$width" "$height"); then
      log "display $ordinal has an unusable resolution ${width}x${height}"
      continue
    fi
    case "$bucket" in
      Standard)
        rank=$rank_Standard
        rank_Standard=$((rank_Standard + 1))
        counter=$counter_Standard
        ;;
      Ultrawide)
        rank=$rank_Ultrawide
        rank_Ultrawide=$((rank_Ultrawide + 1))
        counter=$counter_Ultrawide
        ;;
    esac
    if ! picture=$(pick_at "$work/$bucket.list" "$counter" "$rank"); then
      log "display $ordinal has no $bucket images; leaving it unchanged"
      printf '\n' >>"$work/expected"
      continue
    fi
    printf '%s\n' "$picture" >>"$work/expected"
    log "display $ordinal ${width}x${height} -> $bucket $(basename "$picture")"
    # NSWorkspace is broken on macOS 26+: setDesktopImageURL applies one image
    # to every display or silently keeps the old one. System Events still lands
    # per desktop; it needs Automation approval once.
    /usr/bin/osascript - "$ordinal" "$picture" <<'APPLESCRIPT'
on run argv
  set idx to (item 1 of argv) as integer
  set picture_path to item 2 of argv
  tell application "System Events" to set picture of (item idx of (every desktop)) to picture_path
end run
APPLESCRIPT
    case "$bucket" in
      Standard) used_Standard=1 ;;
      Ultrawide) used_Ultrawide=1 ;;
    esac
    set=$((set + 1))
  done <"$work/displays"
  if [ "$used_Standard" -eq 1 ]; then
    printf '%s\n' "$((counter_Standard + 1))" >"$state/counter-Standard"
  fi
  if [ "$used_Ultrawide" -eq 1 ]; then
    printf '%s\n' "$((counter_Ultrawide + 1))" >"$state/counter-Ultrawide"
  fi
  if [ "$set" -eq 0 ]; then
    log "no display could be set"
    return 1
  fi
  # Read back through the same System Events model used to set, joined without
  # a trailing newline so it compares line-for-line with `expected`.
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
  if ! diff -u "$work/expected" "$work/applied"; then
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
    sync_cache
    apply
    ;;
  apply)
    lock
    apply
    ;;
  classify)
    shift
    classify "$@"
    ;;
  pick-at)
    shift
    pick_at "$@"
    ;;
  counter)
    shift
    if [ "$#" -ne 1 ]; then
      log "usage: wallpapers counter <state-file>"
      exit 2
    fi
    counter_of "$1"
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
    log "usage: wallpapers [sync|apply|classify W H|pick-at LIST COUNTER RANK|counter FILE|buckets DIR OUT]"
    exit 2
    ;;
esac
