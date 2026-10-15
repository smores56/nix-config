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
- **The offsite mirror is verified — incrementally.** The offsite copy logs
  every file it wrote (`--use-json-log`), and the run finishes with
  `rclone check --checksum --one-way --files-from <those paths>`, so only what
  changed is re-read instead of the whole tree (a full walk of a large unchanged
  dataset reads the entire mirror for no new information). When the copy wrote
  nothing the check is skipped: the mirror is unchanged since the last run. A
  skipped check never clears a prior failure's `BACKUP-FAILED` marker — only a
  run that actually verified the mirror does. A periodic whole-mirror
  `--full-check` (per-dataset `fullCheckSchedule`) still walks everything to
  catch drift in old files. rclone exits 0 even when
  it compared nothing, so the `"<n> hashes could not be checked"` summary is
  parsed and any non-zero count fails the run: an unverified mirror is not a
  backup.
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

| Name | Source | Schedule | Full check | Offsite | preBackup |
| --- | --- | --- | --- | --- | --- |
| `Photos` | `/var/lib/media/Photos` | 03:00 | Sun 06:00 | yes | `pg_dump -Fc` of `immich` into `current/db/immich-<date>.dump` |
| `Videos` | `/var/lib/media/Videos` | 01:00 | Sun 07:00 | yes | — |
| `Music` | `/var/lib/media/Music` | 05:00 | Sun 08:00 | yes | — |

Every dataset excludes `/.cache/**`, `**/.cache/**` and `/rclone.conf` by
default (the `excludes` option default). That keeps regenerable caches (at the
source root and nested) and a stray `rclone.conf` at the source root out of
both mirrors — it does **not** make the mirrors secret-free: a credential-shaped
file anywhere else (e.g. `Photos/backup/rclone.conf`, a `.env`) is copied unless
you add it to `excludes`. Both cache patterns are needed: rclone's `**/`
requires a preceding path segment, so it misses a `.cache` sitting at the
source root. `Photos` additionally excludes `/thumbs/**` and
`/encoded-video/**` — regenerable Immich derived assets that Immich rebuilds
from the originals, so they need not occupy a mirror.

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
5. Verify the offsite mirror: `rclone check --checksum --one-way` scoped with
   `--files-from` to the paths the offsite copy wrote this run, or skipped
   entirely when it wrote nothing. A `--full-check` run (per-dataset
   `fullCheckSchedule`) walks the whole mirror instead.
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
a handful of files *by path* (`rclone copyto`). The nightly check now verifies
only the files that changed, so the whole-mirror content verification is this
`FULL_OFFSITE=1` walk (or a manual `backup ... --full-check`). Opt into the
expensive walk with `FULL_OFFSITE=1`, which streams progress so it never looks
hung. Per-fetch `FETCH_TIMEOUT` (default 300s) and the same network flags the
backup uses keep a wedged Proton session from hanging the drill. Like `backup`,
the drill takes the host-wide `/run/lock/media-backup.lock`, so it serializes
with any scheduled run instead of racing it for the single-use Proton session.

## Pruning a mirror (one-time)

The routine pipeline only ever *adds*: `copy` never deletes, so a file removed
from the source lives on in `current/` and in `proton:<Name>` forever. That is
the point — an accidental source deletion cannot reach the backup. There is no
automated prune, and there should not be one: making the mirror track source
deletions is exactly the `sync` failure mode the pipeline refuses.

When you *deliberately* want to reclaim the space (e.g. after culling the photo
library), do it as a one-off, reviewed operation. The local mirror holds one
thing the source does not — the `preBackup` database dumps under `db/` — so that
path MUST be excluded or `sync` deletes every dump:

```sh
# 1. Review what would be deleted. --dry-run touches nothing.
sudo rclone sync /var/lib/media/Photos /var/backup/Photos/current \
  --config /var/lib/backup/rclone.conf \
  --exclude '/db/**' \
  --exclude '/.cache/**' --exclude '**/.cache/**' --exclude '/rclone.conf' \
  --dry-run

# 2. Same command without --dry-run deletes the orphans at the destination.
```

Notes:

- **`--exclude '/db/**'` is not optional.** `db/` exists only in the mirror (it
  is the `preBackup` dump target), so without the exclude `sync` lists every
  dump for deletion — including the newest local recovery point.
- `versions/<date>/` holds only *overwritten* files, never deletions — it is not
  a recovery path for culled images. Until Proton is pruned too, the offsite
  mirror is the safety net.
- `thumbs/` and `encoded-video/` are excluded from the dataset (regenerable), so
  new runs no longer copy them, but they remain in the existing mirrors. To
  reclaim them, delete the subtrees explicitly from both mirrors:
  `rclone delete /var/backup/Photos/current/thumbs` and `.../encoded-video`, and
  `rclone purge proton:Photos/thumbs` and `proton:Photos/encoded-video`.
- The offsite leg needs the same treatment, but a bare `sync` against Proton
  aborts its delete phase on any IO error. For a whole subtree, `rclone purge`
  the affected `proton:<Name>/<subtree>` and re-`copy` from the (now smaller)
  source; for scattered files use the `--files-from` recipe below.
- Run it under the host lock (or outside the backup windows) so it does not race
  a scheduled run for the single-use Proton session.
- This is a **one-time** operation. Do not put it on a timer or make it routine:
  a mirror that follows deletions is no longer a backup.

### Pruning scattered files (`--files-from`)

`sync` walks one directory; for a culled photo library the removed files are
scattered across `library/<year>/<month>/<day>/…`, and the offsite leg cannot take
a bare `sync` at all. Delete the exact set instead — same one-time rules apply:

```sh
# One path per line, RELATIVE to the dataset root, e.g.
#   library/admin/2021/2021-05-03/IMG_1234.jpg
LIST=~/photos-purge-list.txt

for target in /var/backup/Photos/current proton:Photos; do
  sudo flock /run/lock/media-backup.lock rclone --config /var/lib/backup/rclone.conf \
    delete "$target" --files-from "$LIST" --dry-run -v   # drop --dry-run to delete
done
```

- **Empty the source first.** The files must already be gone from the source
  (e.g. empty the Immich trash after culling); while they are still present the
  next `rclone copy` re-adds them and the purge is undone the same night.
- `--files-from` deletes only the listed files and leaves `db/**` and everything
  else untouched. It also prunes the walk — rclone descends only into directories
  that prefix a listed path, so it does not enumerate the whole mirror (crucial
  on Proton, where a full walk is rate-limited and slow).
- Run under the host lock (`flock /run/lock/media-backup.lock`) so it cannot race
  a scheduled run for the single-use Proton session.

## Adding a dataset

Declare it and nothing else — the service, timer, local mirror, offsite mirror,
check, marker and alert are generated:

```nix
dotfiles.backup.datasets.Books = {
  schedule = "*-*-* 07:00:00";
  # fullCheckSchedule = "Sun *-*-* 06:00:00";  # extra whole-mirror check
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
  That is deliberate for backup safety; there is no automated retention/prune
  tooling. For the deliberate one-off, see
  [Pruning a mirror](#pruning-a-mirror-one-time).
- `dotfiles.immich.backup` and the old restic/Immich-specific pipeline have
  been removed; these generic datasets replace them.
- The offsite copy logs each copied filename at INFO (to extract changed paths),
  so source filenames reach journald on every run that copies files — previously
  they were suppressed at NOTICE. journald is root-only and local.
- The `--files-from` list is a 0600 temp file removed in a `finally`; a hard kill
  (systemd `TimeoutStartSec`, OOM) can leave it in `$TMPDIR`.
- A `fullCheckSchedule` run re-runs the whole dataset — `preBackup` (an extra
  `pg_dump` for Photos) and both copies — not only the check.

### Hardening not yet done (accepted, from the final review)

- The backup service runs as root with no systemd sandboxing
  (`ProtectSystem`/`ReadWritePaths`/`NoNewPrivileges`/`PrivateTmp`); it feeds
  source filenames through rclone, so a parser/write flaw would be uncontained.
- The stall watchdog and unchecked-hash guard `re.search` over every relayed
  line, which includes source filenames; a file deliberately named to embed
  `Transferred:`/`Checks:`/`hashes could not be checked` can forge a stall or a
  spurious failure.
- Only systemd's `RequiresMountsFor` guards the backup disk: a manual/seed
  `backup` run with the disk absent writes the whole mirror onto `/` and
  reports success.
- `/var/lib/backup/rclone.conf` is documented as 0600/root but nothing creates
  or enforces it; a looser-mode copy is accepted silently.
- Every verification layer (both copies, `rclone check`, the drill) applies the
  same exclude list, so an over-broad or mistyped exclude removes files from the
  source listing, both mirrors, the check, and the drill sample alike — the loss
  is invisible. Keep excludes narrow and review them.
- The nightly pipeline checks local↔remote, never source↔local; source-side
  under-copy is only caught by the manual drill's sample.
- The restore drill restores the newest dump as the `postgres` superuser, so a
  dump shaped via a compromised Immich DB executes as that user.
- The drill is only syntax-checked in CI (not run); it scrapes the unit's
  `ExecStart` via `xargs` (quote-lossy) and ignores a custom `mountPoint`.
- `--timeout` (driver, non-rclone steps) defaults to 12h and is not forwarded
  from the dataset option — systemd `TimeoutStartSec` is the real bound.
- The failure marker embeds raw rclone output and is unbounded; the lock file is
  created but never re-hardened against a pre-existing looser mode.
