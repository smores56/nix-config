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
- **Local deletion non-propagation via `--backup-dir`.** When a file changes,
  the previous revision is moved to `versions/<date>/` instead of being
  clobbered. Deleted source files stay in `versions/`.
- **The offsite copy has no `--backup-dir`.** Versions are local-only; Proton is
  a plain append-only mirror that is never pruned. Stale files there are
  harmless and cannot be removed by a compromised local box.
- **The offsite mirror is verified.** Each run finishes with
  `rclone check --checksum --one-way`. rclone exits 0 even when it compared
  nothing, so the `"<n> hashes could not be checked"` summary is parsed and any
  non-zero count fails the run: an unverified mirror is not a backup.
- **A run that stalls is killed and retried.** rclone's own idle timeout does
  not catch a wedged upload session (one such hang held the shared Proton lock
  for 18h). A stats-based watchdog (`stallTimeout`, default 30m) aborts a step
  whose `Transferred:` *and* `Checks:` counters stop advancing, then retries —
  `copy` is resumable.

## Layout on a host

| Path | What |
| --- | --- |
| `/var/lib/media/<Name>` | live source (Disk 1), root-owned, `a+rX` |
| `/var/backup/<Name>/current` | local mirror of the source (Disk 2) |
| `/var/backup/<Name>/versions/<date>` | files overwritten or deleted from `current` |
| `/var/backup/<Name>/db/` | pre-backup database dumps (dataset's `preBackup`) |
| `/var/backup/<Name>/BACKUP-FAILED` | marker written by `ExecStopPost` when a run stops non-`success` |
| `/var/lib/backup/rclone.conf` | Proton remote config, mode 0600, **runtime only — never in the Nix store** |
| `/run/lock/media-backup.lock` | host-wide `flock`; all datasets share one Proton credential |

Proton paths are the dataset name under the remote: `proton:<Name>` — on
smortress, `proton:Photos`, `proton:Videos`, `proton:Music`.

## Datasets on smortress

| Name | Source | Schedule | Offsite | preBackup |
| --- | --- | --- | --- | --- |
| `Photos` | `/var/lib/media/Photos` | 03:00 | yes | `pg_dump -Fc` of `immich` into `current/db/immich-<date>.dump` |
| `Videos` | `/var/lib/media/Videos` | 01:00 | yes | — |
| `Music` | `/var/lib/media/Music` | 05:00 | yes | — |

Every dataset excludes `**/.cache/**` and `/rclone.conf` so a stray credential
copy or a regenerable cache never enters a mirror.

## How a run works

1. `flock /run/lock/media-backup.lock` — Proton refresh tokens are single-use;
   two concurrent rclone clients blank the session (rclone#9880), so runs
   serialize. A queued dataset simply waits.
2. `preBackup` (if set) runs with `BACKUP_DATE`, `BACKUP_CURRENT`,
   `BACKUP_SOURCE` in the environment. Writes are atomic (`.tmp` + `mv`).
3. Local copy → `current/`, overwritten revisions to `versions/<date>/`.
4. Offsite copy → `proton:<Name>` with
   `--protondrive-replace-existing-draft=true` (uploads only; never used to
   delete).
5. `rclone check --checksum --one-way` against the offsite mirror.
6. On success the unit is done. On failure `ExecStopPost` writes
   `BACKUP-FAILED`, and `onFailure` pushes an ntfy alert.

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

**Database (Photos).** The newest dump is in `current/db/`:

```sh
runuser -u postgres -- createdb -O postgres restored
runuser -u postgres -- pg_restore --no-owner -d restored \
  /var/backup/Photos/current/db/immich-<date>.dump
```

**Drill the whole thing.** [`drills/restore-drill.sh`](./drills/restore-drill.sh)
is the executable form of the above: size/count parity across
source/local/offsite, sha256 of N random files across all three, and an optional
database restore into a scratch Postgres:

```sh
sudo bash modules/features/backup/drills/restore-drill.sh Photos
DRILL_PG_DB=immich sudo bash modules/features/backup/drills/restore-drill.sh Photos
```

## Adding a dataset

Declare it and nothing else — the service, timer, local mirror, offsite mirror,
check, marker and alert are generated:

```nix
dotfiles.backup.datasets.Books = {
  schedule = "*-*-* 07:00:00";
  # timeout = "12h";       # wall-clock backstop
  # offsite = false;       # local-only dataset
  # stallTimeout = "30m";  # "0" disables the watchdog
  # excludes = [ "**/.cache/**" ];
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
- The offsite mirror never prunes, so a file deleted from the source lives on in
  Proton forever. That is deliberate for backup safety; there is no
  retention/prune tooling.
- `dotfiles.immich.backup` (the old restic/Immich-specific pipeline) still
  exists and is being retired in favour of these datasets.
