#!/usr/bin/env bash
# Exercise modules/features/backup/backup.sh against real rclone local remotes.
#
# Usage: bash tests/backup_plain.sh <path-to-backup.sh>
#
# Covers the guarantees the backup units depend on: copy (never sync) with a
# versioned local mirror, an append-only plain offsite tree, a checksum check
# scoped to the changed paths, a size-only check for a filesystem-path offsite
# target (the Proton mount), empty-source refusal, same-day version collisions,
# marker lifecycle, the whole-tree --full-check, the local-only verify pair, the
# preBackup environment, the missing offsite RC socket refusal, and the stall
# watchdog. Everything lives under a temporary directory; no host lock or Proton
# remote is touched.
set -euo pipefail

DRIVER=${1:?usage: backup_plain.sh <path-to-backup.sh>}
ROOT=$(mktemp -d)
SRC=$ROOT/source
BACKUP_ROOT=$ROOT/backup
CONF=$ROOT/rclone.conf
DATE=2026-10-03
LAST=$ROOT/last.log

cleanup() { rm -rf "$ROOT"; }
trap cleanup EXIT

export HOME=$ROOT/home
export BACKUP_ALLOW_NO_LOCK=1
mkdir -p "$HOME" "$SRC"

# A local "remote" via the alias backend: proton:<Name> is $ROOT/proton/<Name>.
printf '[test]\ntype = alias\nremote = %s/proton\n' "$ROOT" >"$CONF"
chmod 0600 "$CONF"

fail() {
  echo "FAIL: $*" >&2
  echo "--- driver log ---" >&2
  cat "$LAST" >&2 || true
  echo "--- tree ---" >&2
  find "$BACKUP_ROOT" "$ROOT/proton" -type f 2>/dev/null >&2 || true
  exit 1
}

# Run the driver for the Photos dataset; arguments are appended (e.g. --offsite).
driver() {
  : >"$LAST"
  bash "$DRIVER" \
    --name Photos \
    --source "$SRC" \
    --backup-root "$BACKUP_ROOT" \
    --remote test \
    --rclone-config "$CONF" \
    --date "$DATE" \
    --stall-timeout 0 \
    --timeout 5m \
    --no-lock \
    "$@" >>"$LAST" 2>&1
}

expect_ok() {
  driver "$@" || fail "driver failed (args: $*)"
}

# Run the driver against a filesystem-path offsite target (the host's Proton
# mount): no rclone config at all, because the mount owns the credential.
PATH_ROOT=$ROOT/mount
driver_path() {
  : >"$LAST"
  bash "$DRIVER" \
    --name Photos \
    --source "$SRC" \
    --backup-root "$BACKUP_ROOT" \
    --remote "$PATH_ROOT" \
    --date "$DATE" \
    --stall-timeout 0 \
    --timeout 5m \
    --no-lock \
    "$@" >>"$LAST" 2>&1
}

echo one >"$SRC/one.txt"
mkdir -p "$SRC/sub"
echo nested >"$SRC/sub/nested.txt"

# 1. Seed: local current/ + plain offsite tree, verified and marked successful.
expect_ok --offsite
[[ -f $BACKUP_ROOT/Photos/current/one.txt ]] || fail "local mirror missing one.txt"
[[ -f $BACKUP_ROOT/Photos/current/sub/nested.txt ]] || fail "local mirror missing nested file"
[[ -f $ROOT/proton/Photos/one.txt ]] || fail "offsite mirror missing one.txt"
[[ -f $BACKUP_ROOT/Photos/BACKUP-LAST-SUCCESS ]] || fail "no success marker after a verified run"
[[ ! -e $BACKUP_ROOT/Photos/BACKUP-FAILED ]] || fail "failure marker survived a successful run"
[[ ! -e $ROOT/proton/Photos/versions ]] || fail "offsite tree has a versions/ directory"
grep -q -- "--files-from0" "$LAST" || fail "check was not scoped to the copied paths"
if grep -qE 'rclone .* sync ' "$LAST"; then fail "driver used sync"; fi

offsite_copy=$(grep -F "copy $BACKUP_ROOT/Photos/current test:Photos" "$LAST" || true)
[[ -n $offsite_copy ]] || fail "no offsite copy step"
[[ $offsite_copy != *--backup-dir* ]] || fail "offsite copy has a --backup-dir"

# 2. copy, never sync: a source deletion must not reach either mirror.
rm "$SRC/one.txt"
echo two >"$SRC/two.txt"
expect_ok --offsite
[[ -f $BACKUP_ROOT/Photos/current/one.txt ]] || fail "local mirror dropped a deleted source file"
[[ -f $ROOT/proton/Photos/one.txt ]] || fail "offsite mirror dropped a deleted source file"
[[ -f $BACKUP_ROOT/Photos/current/two.txt ]] || fail "new source file was not copied"

# 3. Versioned overwrite: the old revision lands under versions/<date>[T...].
echo changed >"$SRC/two.txt"
expect_ok --offsite
grep -qx changed "$BACKUP_ROOT/Photos/current/two.txt" || fail "current/ was not updated"
old=$(find "$BACKUP_ROOT/Photos/versions" -type f -name two.txt | head -n1)
[[ -n $old ]] || fail "overwritten revision was not versioned"
[[ $(cat "$old") == two ]] || fail "versioned revision has the wrong content"
version_dirs=$(find "$BACKUP_ROOT/Photos/versions" -mindepth 1 -maxdepth 1 -type d | wc -l)
((version_dirs >= 2)) || fail "same-day collision did not create a unique version folder"

# 4. --one-way: an extra file on the append-only remote is not a difference.
echo extra >"$ROOT/proton/Photos/stale.txt"
expect_ok --offsite
[[ -f $ROOT/proton/Photos/stale.txt ]] || fail "copy deleted a remote-only file"

# 5. A skipped check never clears a prior failure, and the timestamp is held.
touch "$BACKUP_ROOT/Photos/BACKUP-FAILED"
before=$(cat "$BACKUP_ROOT/Photos/BACKUP-LAST-SUCCESS")
expect_ok --offsite
grep -q 'no offsite changes; skipping verification' "$LAST" || fail "unchanged run was not skipped"
[[ -f $BACKUP_ROOT/Photos/BACKUP-FAILED ]] || fail "a skipped check cleared the failure marker"
[[ $(cat "$BACKUP_ROOT/Photos/BACKUP-LAST-SUCCESS") == "$before" ]] ||
  fail "a skipped check refreshed the success timestamp"

# A verified run removes the marker again.
echo again >"$SRC/two.txt"
expect_ok --offsite
[[ ! -e $BACKUP_ROOT/Photos/BACKUP-FAILED ]] || fail "verified run did not clear the failure marker"
[[ $(cat "$BACKUP_ROOT/Photos/BACKUP-LAST-SUCCESS") != "$before" ]] ||
  fail "verified run did not refresh the success timestamp"

# 6. Empty and missing sources are refused, and leave a detailed marker.
mkdir "$ROOT/empty"
: >"$LAST"
if bash "$DRIVER" --name Photos --source "$ROOT/empty" --backup-root "$BACKUP_ROOT" \
  --remote test --rclone-config "$CONF" --date "$DATE" --stall-timeout 0 \
  --no-lock --offsite >>"$LAST" 2>&1; then
  fail "an empty source was accepted"
fi
grep -q 'is empty; refusing to back up nothing' "$BACKUP_ROOT/Photos/BACKUP-FAILED" ||
  fail "empty-source failure marker has no detail"

if bash "$DRIVER" --name Missing --source "$ROOT/nope" --backup-root "$BACKUP_ROOT" \
  --remote test --rclone-config "$CONF" --date "$DATE" --stall-timeout 0 \
  --no-lock >>"$LAST" 2>&1; then
  fail "a missing source was accepted"
fi
grep -q 'is not a directory' "$BACKUP_ROOT/Missing/BACKUP-FAILED" ||
  fail "missing-source failure marker has no detail"

# 7. --full-check walks the whole tree instead of only the changed paths.
expect_ok --offsite --full-check
check_line=$(grep -F 'check --checksum --one-way' "$LAST" || true)
[[ -n $check_line ]] || fail "full-check run had no check step"
[[ $check_line != *--files-from0* ]] || fail "full check was still scoped to changed paths"

# 8. A local-only dataset verifies source -> local mirror.
LOCAL_ROOT=$ROOT/backup-local
: >"$LAST"
bash "$DRIVER" --name Music --source "$SRC" --backup-root "$LOCAL_ROOT" \
  --remote test --rclone-config "$CONF" --date "$DATE" --stall-timeout 0 \
  --timeout 5m --no-lock >>"$LAST" 2>&1 || fail "local-only run failed"
grep -qF "check --checksum --one-way $SRC $LOCAL_ROOT/Music/current --files-from0" "$LAST" ||
  fail "local-only check did not compare source against the local mirror"
[[ -f $LOCAL_ROOT/Music/BACKUP-LAST-SUCCESS ]] || fail "local-only run left no success marker"

# 9. preBackup sees BACKUP_DATE, BACKUP_CURRENT, and BACKUP_SOURCE.
# The shebang is the test's own bash: the Nix build sandbox has no /usr/bin/env.
{
  printf '#!%s\n' "$(command -v bash)"
  cat <<'EOF'
printf '%s|%s|%s\n' "$BACKUP_DATE" "$BACKUP_CURRENT" "$BACKUP_SOURCE" >"$HOOK_OUT"
EOF
} >"$ROOT/pre.sh"
chmod +x "$ROOT/pre.sh"
: >"$LAST"
HOOK_OUT=$ROOT/hook.out bash "$DRIVER" --name Hooked --source "$SRC" \
  --backup-root "$BACKUP_ROOT" --remote test --rclone-config "$CONF" \
  --date "$DATE" --stall-timeout 0 --timeout 5m --no-lock \
  --pre-backup "$ROOT/pre.sh" >>"$LAST" 2>&1 || fail "preBackup run failed"
[[ $(cat "$ROOT/hook.out") == "$DATE|$BACKUP_ROOT/Hooked/current|$SRC" ]] ||
  fail "preBackup environment is wrong: $(cat "$ROOT/hook.out")"

# 10. A path remote writes <path>/<Name>, needs no rclone config, and verifies
# by size instead of hashing through FUSE.
mkdir -p "$PATH_ROOT"
echo path >"$SRC/three.txt"
driver_path --offsite || fail "path-form offsite run failed"
[[ -f $PATH_ROOT/Photos/three.txt ]] || fail "path-form target did not receive the copy"
[[ ! -e $PATH_ROOT/Photos/versions ]] || fail "path-form target has a versions/ directory"
grep -qF "copy $BACKUP_ROOT/Photos/current $PATH_ROOT/Photos" "$LAST" ||
  fail "path-form offsite copy did not target <path>/<Name>"
grep -q 'check --size-only --one-way' "$LAST" || fail "path-form check was not size-only"
grep -q -- '--files-from0' "$LAST" || fail "path-form check was not scoped to changed paths"
if grep -q 'protondrive-replace-existing-draft' "$LAST"; then
  fail "path-form copy used a Proton remote backend flag"
fi
if grep -q -- '--config' "$LAST"; then fail "path-form run used an rclone config"; fi

# The path-form full check still walks the whole tree, size-only.
driver_path --offsite --full-check || fail "path-form full-check run failed"
path_full=$(grep -F 'check --size-only --one-way' "$LAST" || true)
[[ -n $path_full ]] || fail "path-form full check had no size-only check step"
[[ $path_full != *--files-from0* ]] || fail "path-form full check was still scoped"

# 11. A path target told to use a mount RC socket must have a live one: without
# the mount's upload queue there is no proof the copy ever reached the backend,
# so the run fails before copying and leaves a detailed marker.
if driver_path --offsite --offsite-rc-socket "$ROOT/missing.sock"; then
  fail "a missing offsite RC socket was accepted"
fi
grep -q 'offsite RC socket .* is missing' "$BACKUP_ROOT/Photos/BACKUP-FAILED" ||
  fail "missing RC socket left no detailed failure marker"

# 12. Stall watchdog: a step whose counters stop advancing is killed, retried,
# and fails the run. BACKUP_STATS_INTERVAL=1 keeps the test quick; production
# keeps the 30s cadence and the Nix assertion keeps stallTimeout >= 60s.
mkdir -p "$ROOT/fakebin"
{
  printf '#!%s\n' "$(command -v bash)"
  cat <<'EOF'
printf 'Transferred:   \t 1 B / 1 B, 100%%, 0 B/s, ETA -\nChecks:                 0 / 0, -\n' >&2
exec sleep 300
EOF
} >"$ROOT/fakebin/rclone"
chmod +x "$ROOT/fakebin/rclone"
: >"$LAST"
stalled_rc=0
PATH="$ROOT/fakebin:$PATH" BACKUP_STATS_INTERVAL=1 bash "$DRIVER" \
  --name Stalled --source "$SRC" --backup-root "$BACKUP_ROOT" \
  --remote test --rclone-config "$CONF" --date "$DATE" --stall-timeout 2s \
  --timeout 5m --no-lock --offsite >>"$LAST" 2>&1 || stalled_rc=$?
((stalled_rc != 0)) || fail "a stalled transfer was reported as success"
grep -q 'no transfer progress for 2s' "$LAST" || fail "stall was not reported"
retries=$(grep -c 'stalled, retry' "$LAST" || true)
((retries == 2)) || fail "stalled step was not retried twice (got $retries)"
grep -q 'no transfer progress' "$BACKUP_ROOT/Stalled/BACKUP-FAILED" ||
  fail "stall left no detailed failure marker"

# 13. A dataset queued behind the shared lock defers instead of spending its
# whole run budget waiting: it exits 75 (a result the units treat as success),
# writes no failure marker, and leaves the success timestamp untouched. A
# queued run must never look like a broken one.
LOCK=$ROOT/media-backup.lock
: >"$LOCK"
exec 8>>"$LOCK"
flock 8
# Case 11 left a failure marker behind; a deferral must not add or clear one.
rm -f "$BACKUP_ROOT/Photos/BACKUP-FAILED"
before_defer=$(cat "$BACKUP_ROOT/Photos/BACKUP-LAST-SUCCESS")
: >"$LAST"
defer_rc=0
BACKUP_LOCK_PATH=$LOCK bash "$DRIVER" \
  --name Photos --source "$SRC" --backup-root "$BACKUP_ROOT" \
  --remote test --rclone-config "$CONF" --date "$DATE" --stall-timeout 0 \
  --timeout 5m --lock-wait 1s --offsite >>"$LAST" 2>&1 || defer_rc=$?
((defer_rc == 75)) || fail "a queued run exited $defer_rc instead of deferring (75)"
grep -q 'backup deferred' "$LAST" || fail "deferral was not reported"
[[ ! -e $BACKUP_ROOT/Photos/BACKUP-FAILED ]] || fail "a deferred run wrote a failure marker"
[[ $(cat "$BACKUP_ROOT/Photos/BACKUP-LAST-SUCCESS") == "$before_defer" ]] ||
  fail "a deferred run refreshed the success timestamp"

# Releasing the lock lets the same dataset run normally on the shared path.
flock -u 8
exec 8>&-
: >"$LAST"
BACKUP_LOCK_PATH=$LOCK bash "$DRIVER" \
  --name Photos --source "$SRC" --backup-root "$BACKUP_ROOT" \
  --remote test --rclone-config "$CONF" --date "$DATE" --stall-timeout 0 \
  --timeout 5m --lock-wait 5s --offsite >>"$LAST" 2>&1 ||
  fail "a run could not take a free shared lock"
grep -q 'backup deferred' "$LAST" && fail "an uncontended run deferred"

echo "backup_plain.sh: ok"
