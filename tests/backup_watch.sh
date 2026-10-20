#!/usr/bin/env bash
# Exercise modules/features/backup/backup_watch.sh without a real dataset.
#
# Usage: bash tests/backup_watch.sh <path-to-backup_watch.sh>
#
# Covers the behaviour the backup units depend on: one request per quiet batch
# (coalescing), the ignore rules, and a follow-up request while a backup is
# marked running. A one-second debounce keeps the test quick.
set -euo pipefail

WATCHER=${1:?usage: backup_watch.sh <path-to-backup_watch.sh>}
root=$(mktemp -d)
source_dir=$root/source
queue_dir=$root/queue
running_file=$root/backup.running
pid=""

cleanup() {
  if [[ -n $pid ]]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  rm -rf "$root"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  echo "--- watcher log ---" >&2
  echo "--- queue ---" >&2
  ls -la "$queue_dir" >&2 || true
  exit 1
}

queue_count() {
  find "$queue_dir" -maxdepth 1 -type f \( -name '*.queue' -o -name '*.req' \) | wc -l
}

wait_for_count() {
  local want=$1 i
  for ((i = 0; i < 50; i++)); do
    (($(queue_count) == want)) && return 0
    sleep 0.1
  done
  return 1
}

mkdir -p "$source_dir" "$queue_dir"
bash "$WATCHER" \
  --source "$source_dir" \
  --queue-dir "$queue_dir" \
  --running-file "$running_file" \
  --debounce-seconds 1 \
  --ignore thumbs \
  --ignore 'encoded-video' &
pid=$!

# Warm up: inotifywait installs the recursive watches asynchronously, so give
# it a moment and then prove a change is seen before asserting on counts.
sleep 1
touch "$source_dir/warmup.jpg"
wait_for_count 1 || fail "watcher never queued the warmup change"
rm -f "$queue_dir"/*.queue "$queue_dir"/*.req
sleep 0.2

# A single change produces exactly one request after the quiet window.
touch "$source_dir/one.jpg"
wait_for_count 1 || fail "single change did not queue"
sleep 1.3
(($(queue_count) == 1)) || fail "a quiet batch produced more than one request"
rm -f "$queue_dir"/*.queue

# A burst is coalesced into one batch.
touch "$source_dir/burst-a.jpg" "$source_dir/burst-b.jpg" "$source_dir/burst-c.jpg"
wait_for_count 1 || fail "burst did not queue"
sleep 1.3
(($(queue_count) == 1)) || fail "burst produced more than one request"
rm -f "$queue_dir"/*.queue

# Ignored paths never queue: hidden components, scratch suffixes, OS junk, and
# the per-dataset component globs.
mkdir -p "$source_dir/.cache" "$source_dir/thumbs" "$source_dir/encoded-video"
touch "$source_dir/.cache/x" "$source_dir/.hidden.jpg" "$source_dir/x.part" \
  "$source_dir/x.tmp" "$source_dir/Thumbs.db" "$source_dir/desktop.ini" \
  "$source_dir/thumbs/a.jpg" "$source_dir/encoded-video/a.mp4"
sleep 1.5
(($(queue_count) == 0)) || fail "an ignored change queued a request"

# While a run is active, a change becomes one follow-up request (not a plain
# queue entry) and is still not coalesced away.
touch "$running_file"
touch "$source_dir/followup.jpg"
wait_for_count 1 || fail "follow-up change did not queue"
find "$queue_dir" -maxdepth 1 -name 'followup-*.req' | grep -q . ||
  fail "active run did not produce a followup-*.req file"
rm -f "$queue_dir"/*.req
rm -f "$running_file"

# Once the run marker is gone, requests are plain queue entries again.
touch "$source_dir/after-run.jpg"
wait_for_count 1 || fail "change after the run did not queue"
find "$queue_dir" -maxdepth 1 -name '*.queue' | grep -q . ||
  fail "post-run change was not a plain queue entry"
(($(queue_count) == 1)) || fail "post-run batch produced more than one request"

echo "backup_watch.sh: ok"
