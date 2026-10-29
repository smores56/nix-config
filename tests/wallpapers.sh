#!/usr/bin/env bash
# Aspect buckets, random-without-replacement queues and per-display picks are
# pure: fixed dimensions and a fixed queue always yield the same image.
# Usage: wallpapers.sh <wallpapers>
set -euo pipefail

wallpapers=$1
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() {
  echo "FAIL $*" >&2
  exit 1
}

expect() {
  local want=$1
  shift
  local got
  got=$("$@") || fail "command failed: $*"
  [ "$got" = "$want" ] || fail "got '$got', want '$want' from: $*"
}

# 16:9 and friends are standard; 21:9 and wider are ultrawide; 2.0 is the edge.
expect Standard "$wallpapers" classify 2560 1440
expect Standard "$wallpapers" classify 1920 1080
expect Standard "$wallpapers" classify 1999 1000
expect Ultrawide "$wallpapers" classify 2000 1000
expect Ultrawide "$wallpapers" classify 3440 1440
expect Ultrawide "$wallpapers" classify 5120 2160

# Bad dimensions must fail loudly, not silently pick a bucket.
if "$wallpapers" classify 1920 0 >/dev/null 2>&1; then
  fail "zero height accepted"
fi
if "$wallpapers" classify abc 1080 >/dev/null 2>&1; then
  fail "non-numeric width accepted"
fi

# Rotation is random without replacement: each bucket keeps a shuffled queue of
# the images it has not shown yet, so one cycle repeats nothing.
mkdir -p "$work/images"
: >"$work/images/a.jpg"
: >"$work/images/b.jpg"
: >"$work/images/c.jpg"
printf '%s\0' \
  "$work/images/a.jpg" \
  "$work/images/b.jpg" \
  "$work/images/c.jpg" >"$work/list"

: >"$work/queue"
for _ in 1 2 3; do
  "$wallpapers" pick "$work/list" "$work/queue" >>"$work/cycle"
done
[ "$(sort -u "$work/cycle" | wc -l)" -eq 3 ] || fail "a cycle repeated an image"
sort "$work/cycle" | diff - <(printf '%s\n' "$work/images/"*.jpg | sort) >/dev/null ||
  fail "a cycle skipped an image"
[ ! -s "$work/queue" ] || fail "the queue was not exhausted after a cycle"

# An exhausted queue refills from the whole bucket and leaves the rest queued.
"$wallpapers" pick "$work/list" "$work/queue" >/dev/null
[ "$(tr '\0' '\n' <"$work/queue" | wc -l)" -eq 2 ] || fail "a new cycle did not refill the queue"

# Two displays of the same aspect in one run never share an image.
: >"$work/pair"
one=$("$wallpapers" pick "$work/list" "$work/pair")
two=$("$wallpapers" pick "$work/list" "$work/pair")
[ "$one" != "$two" ] || fail "same-aspect displays got the same image"

# Even when the queue drains mid-run, the used list keeps the second display of
# that aspect off the first one's image. Two images, one already used, no queue:
# the only correct answer is the unused one.
mkdir -p "$work/two"
: >"$work/two/x.jpg"
: >"$work/two/y.jpg"
printf '%s\0' "$work/two/x.jpg" "$work/two/y.jpg" >"$work/two.list"
: >"$work/two.queue"
printf '%s\0' "$work/two/y.jpg" >"$work/two.used"
expect "$work/two/x.jpg" "$wallpapers" pick "$work/two.list" "$work/two.queue" "$work/two.used"

# A pick that failed to land goes back to the head of the queue for the next
# display or run.
printf '%s\0' "$work/images/b.jpg" >"$work/back"
"$wallpapers" unpick "$work/back" "$work/images/a.jpg"
expect "$work/images/a.jpg" "$wallpapers" pick "$work/list" "$work/back"

# A queue that is a directory is an error, not a silent overwrite.
mkdir -p "$work/qdir"
if "$wallpapers" pick "$work/list" "$work/qdir" >/dev/null 2>&1; then
  fail "a directory queue still picked"
fi

# An unwritable queue is an error, not a pick from a stale queue.
: >"$work/blocker"
if "$wallpapers" pick "$work/list" "$work/blocker/queue" >/dev/null 2>&1; then
  fail "an unwritable queue still picked"
fi

# Entries that left the bucket are dropped instead of being picked.
printf '%s\0' "$work/images/gone.jpg" "$work/images/a.jpg" >"$work/stale"
expect "$work/images/a.jpg" "$wallpapers" pick "$work/list" "$work/stale"
[ ! -s "$work/stale" ] || fail "a vanished file stayed queued"

# An empty bucket (no image of that aspect) is an error, not an empty path.
: >"$work/empty"
if "$wallpapers" pick "$work/empty" "$work/qempty" >/dev/null 2>&1; then
  fail "empty list picked an image"
fi

# The production bucketing path, against real pixels: the folder layout does
# not decide the bucket, the measured aspect does.
mkdir -p "$work/imgs" "$work/out"
magick -size 2000x1000 xc:red "$work/imgs/wide.png"
magick -size 1600x900 xc:blue "$work/imgs/standard.png"
: >"$work/imgs/notes.txt"
"$wallpapers" buckets "$work/imgs" "$work/out"
tr '\0' '\n' <"$work/out/Ultrawide.list" | grep -qxF "$work/imgs/wide.png" ||
  fail "2000x1000 was not bucketed as Ultrawide"
tr '\0' '\n' <"$work/out/Standard.list" | grep -qxF "$work/imgs/standard.png" ||
  fail "1600x900 was not bucketed as Standard"
[ "$(tr '\0' '\n' <"$work/out/Standard.list" | wc -l)" -eq 1 ] ||
  fail "non-image files reach a bucket"

# A name with a control character is skipped rather than forging a record.
mkdir -p "$work/odd" "$work/oddout"
magick -size 2000x1000 xc:green "$work/odd/wide.png"
magick -size 2000x1000 xc:green "$work/odd/$(printf 'bad\nname.png')"
"$wallpapers" buckets "$work/odd" "$work/oddout" 2>/dev/null
[ "$(tr '\0' '\n' <"$work/oddout/Ultrawide.list" | wc -l)" -eq 1 ] ||
  fail "a newline in a filename was bucketed"

# rsync accepts --contimeout only for daemon transports; over `-e ssh` it exits
# with a usage error before transferring, so the timer would fail every run.
script=$(readlink -f "$wallpapers")
if grep -v '^[[:space:]]*#' "$script" | grep -q -- '--contimeout'; then
  fail "daemon-only rsync option breaks the ssh transport"
fi

# Deletions must run after a successful transfer: a kill mid-run would otherwise
# leave the cache half-emptied.
grep -v '^[[:space:]]*#' "$script" | grep -q -- '--delete-after' ||
  fail "rsync must delete after the transfer"

# Every placeholder the module substitutes must be gone from the built script.
if grep -q '@[A-Z]*@' "$script"; then
  fail "an unsubstituted placeholder reached the script"
fi
echo "wallpapers ok"
