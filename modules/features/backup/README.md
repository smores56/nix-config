# Media backup — rclone 3-2-1 to Proton Drive

Generic, dataset-agnostic media backup. One systemd oneshot + timer per
`dotfiles.backup.datasets.<Name>` entry. Nothing here is Immich-specific: a
dataset is a directory on Disk 1, a local mirror on the backup disk (Disk 2),
and — unless `offsite` is disabled — an append-only mirror on Proton Drive
(Disk 3, "offsite").

The rationale for every destructive-looking choice lives as a comment next to
the code in [`backup.py`](./backup.py). This file is the operator's view.

## Guarantees

- **`copy`, never `sync`.** A `sync` would propagate a source deletion into the
  mirror. `copy` only adds or overwrites, so a lost or corrupt source cannot
  reach in and delete the backup.
- **Local versioning via `--backup-dir`.** When a file is overwritten, the
  previous revision is moved to `versions/<date>/` instead of being clobbered.
  `copy` never deletes, so a file deleted at the source is *not* removed from
  `current/` and is never moved to `versions/` — it simply stays in `current/`.
- **The offsite copy has no `--backup-dir`.** Versions are local-only; Proton is
  a plain mirror that is never pruned. It is not append-only for overwrites —
  `copy` replaces a file whose content changed and uploads new ones — but a
  source-side deletion is never propagated, so a deleted file lingers there. A
  compromised local box cannot delete from the remote.
- **The offsite mirror is verified.** Each run finishes with
  `rclone check --checksum --one-way`. rclone exits 0 even when it compared
  nothing, so the `"<n> hashes could not be checked"` summary is parsed and any
  non-zero count fails the run: an unverified mirror is not a backup.
- **A run that stalls is killed and retried.** rclone's own idle timeout does
  not catch a wedged upload session (one such hang held the shared Proton lock
  for 18h). A stats-based watchdog (`stallTimeout`, default 30m) aborts a step
  whose `Transferred:` *and* `Checks:` counters stop advancing, then retries —
  `copy` is resumable. A non-zero `stallTimeout` must be at least 60s (two 30s
  rclone stats intervals) or evaluation fails; `"0"` disables the watchdog.

## Layout on a host

| Path | What |
| --- | --- |
| `/var/lib/media/<Name>` | live source (Disk 1), root-owned, `a+rX` |
| `/var/backup/<Name>/current` | local mirror of the source (Disk 2) |
| `/var/backup/<Name>/versions/<date>` | previous revisions of files that changed (moved out of `current`) |
| `/var/backup/<Name>/db/` | pre-backup database dumps (dataset's `preBackup`) |
| `/var/backup/<Name>/BACKUP-FAILED` | failure marker: detailed one written by the driver, generic fallback by `ExecStopPost` |
| `/var/lib/backup/rclone.conf` | Proton remote config, mode 0600, **runtime only — never in the Nix store** |
| `/run/lock/media-backup.lock` | host-wide, driver-owned lock, mode 0600; all datasets share one Proton credential |

Proton paths are the dataset name under the remote: `proton:<Name>` — on
smortress, `proton:Photos`, `proton:Videos`, `proton:Music`.

## Datasets on smortress

| Name | Source | Schedule | Offsite | preBackup |
| --- | --- | --- | --- | --- |
| `Photos` | `/var/lib/media/Photos` | 03:00 | yes | `pg_dump -Fc` of `immich` into `current/db/immich-<date>.dump` |
| `Videos` | `/var/lib/media/Videos` | 01:00 | yes | — |
| `Music` | `/var/lib/media/Music` | 05:00 | yes | — |

Every dataset excludes `/.cache/**`, `**/.cache/**` and `/rclone.conf` by
default (the `excludes` option default). That keeps regenerable caches (at the
source root and nested) and a stray `rclone.conf` at the source root out of
both mirrors — it does **not** make the mirrors secret-free: a credential-shaped
file anywhere else (e.g. `Photos/backup/rclone.conf`, a `.env`) is copied unless
you add it to `excludes`. Both cache patterns are needed: rclone's `**/`
requires a preceding path segment, so it misses a `.cache` sitting at the
source root.

## How a run works

1. The driver takes the host-wide lock at `/run/lock/media-backup.lock` (created
   mode 0600) — Proton refresh tokens are single-use; two concurrent rclone
   clients blank the session (rclone#9880), so runs serialize. A queued dataset
   simply waits. Manual `backup` runs and the restore drill take the same lock.
2. `preBackup` (if set) runs with `BACKUP_DATE`, `BACKUP_CURRENT`,
   `BACKUP_SOURCE` in the environment. Writes are atomic (`.tmp` + `mv`), and a
   killed dump traps and removes its `.tmp` so no partial file is mirrored.
3. Local copy → `current/`, overwritten revisions to `versions/<date>/`.
4. Offsite copy → `proton:<Name>` with
   `--protondrive-replace-existing-draft=true` (uploads only; never used to
   delete).
5. `rclone check --checksum --one-way` against the offsite mirror.
6. On success the unit is done. On failure the driver writes a detailed
   `BACKUP-FAILED` marker from inside the run; if the run was killed before that
   could happen, `ExecStopPost` writes a generic one (it never overwrites the
   detailed marker). `onFailure` pushes an ntfy alert.

`TimeoutStartSec` (per-dataset `timeout`) is a wall-clock backstop only; a stuck
run is normally caught by `stallTimeout` in ~30m. A `TimeoutStartSec` kill
cannot run the in-process marker, which is why the marker is in `ExecStopPost`.

## Restore procedure

**Files, from the local mirror.** The mirror is a plain directory tree:

```sh
rsync -a /var/backup/Photos/current/ /restore/Photos/
```

**Files, from offsite** (local disk lost):

```sh
rclone copy proton:Photos /restore/Photos \
  --config /var/lib/backup/rclone.conf --transfers 8 --checkers 16
```

Add `--backup-dir`-style recovery by reaching into the same path's local
`versions/` if the mirror still exists.

**Database (Photos).** The newest dump is in `current/db/`. It sits behind the
`0700` backup directory, so the `postgres` user cannot open the path directly —
run this as root and let root stream the file in:

```sh
runuser -u postgres -- createdb -O postgres restored
runuser -u postgres -- pg_restore --no-owner -d restored \
  < /var/backup/Photos/current/db/immich-<date>.dump
```

(To restore from an unprivileged shell, copy the dump somewhere `postgres` can
read first: `install -m 644 …/immich-<date>.dump /tmp/immich.dump`.)

**Drill the whole thing.** [`drills/restore-drill.sh`](./drills/restore-drill.sh)
is the executable form of the above:

```sh
# local parity + local sha256, then restore a few named files from Proton
sudo bash modules/features/backup/drills/restore-drill.sh Photos
# ...plus a scratch-Postgres restore of the newest dump
sudo DRILL_PG_DB=immich bash modules/features/backup/drills/restore-drill.sh Photos
# ...plus the exhaustive (slow) whole-remote walk + rclone check
sudo FULL_OFFSITE=1 bash modules/features/backup/drills/restore-drill.sh Photos
# ...or skip the media phases and re-check only the database
sudo DRILL_PG_DB=immich DRILL_ONLY_DB=1 bash modules/features/backup/drills/restore-drill.sh Photos
```

Every offsite rclone operation walks the entire remote, which is minutes on a
30k-object Proton tree, so the default drill deliberately avoids one: it restores
a handful of files *by path* (`rclone copyto`) and treats the backup's own
nightly `rclone check` as the whole-mirror content verification. Opt into the
expensive walk with `FULL_OFFSITE=1`, which streams progress so it never looks
hung. Per-fetch `FETCH_TIMEOUT` (default 300s) and the same network flags the
backup uses keep a wedged Proton session from hanging the drill. Like `backup`,
the drill takes the host-wide `/run/lock/media-backup.lock`, so it serializes
with any scheduled run instead of racing it for the single-use Proton session.

## Adding a dataset

Declare it and nothing else — the service, timer, local mirror, offsite mirror,
check, marker and alert are generated:

```nix
dotfiles.backup.datasets.Books = {
  schedule = "*-*-* 07:00:00";
  # timeout = "12h";       # wall-clock backstop
  # offsite = false;       # local-only dataset
  # stallTimeout = "30m";  # "0" disables; otherwise must be >= 60s
  # excludes = [ "/.cache/**" "**/.cache/**" "/rclone.conf" ];  # defaults; override to add more
  # postgres = true;       # preBackup dumps Postgres: pg_dump on PATH, After=postgresql.service
  # preBackup = '' ... ''; # runs with BACKUP_* env, before the copy
};
```

The source defaults to `/var/lib/media/<Name>`; set `source` to override. A
dataset needs `dotfiles.backup.enable = true` (the backup disk).

## Known limits

- A kill that lands *after* rclone has committed a file but before it reports
  can leave a retry that re-uploads a zero-byte file; this is not data loss
  (the source and local mirror are intact) but it is not self-healing. Tracked
  as a known low-severity finding.
- The offsite mirror never prunes and keeps no versions: a file deleted from the
  source lives on in Proton forever, and a changed file is overwritten in place.
  That is deliberate for backup safety; there is no retention/prune tooling.
- `dotfiles.immich.backup` and the old restic/Immich-specific pipeline have
  been removed; these generic datasets replace them.
