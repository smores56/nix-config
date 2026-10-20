# Backup — rclone + restic drivers (media and GitHub to Proton)

Generic, dataset-agnostic backup. One systemd oneshot + timer per
`backup.datasets.<Name>` entry, optionally fired early by a filesystem
watcher (`onChange`). A dataset is a directory on Disk 1 and a copy on the
backup disk (Disk 2); unless `offsite` is disabled it also has an
append-only copy on Proton Drive (Disk 3, "offsite").

Two drivers exist side by side while the migration is staged:

- **`driver = "restic"`** (Photos today): a local restic repository on Disk 2
  and an append-only byte copy of that repository on Proton. See
  [Photos: restic driver](#photos-restic-driver).
- **`driver = "rclone"`** (the default; Videos, Music, GitHub,
  CloudflareTofu): the local mirror + Proton mirror below, still implemented by
  [`backup.py`](./backup.py).

The old Photos rclone units are no longer generated. Its existing local mirror
under `/var/backup/Photos/current` and `versions/` is left untouched; it is
retired only after the restic restore drill passes (T10) and T12 removes the
legacy paths. Both drivers share `/run/lock/media-backup.lock`, the
`backup-<name>` unit names, and the `BACKUP-FAILED`/`BACKUP-LAST-SUCCESS`
markers, so `backup-freshness` and `journalctl -u backup-photos` keep working.

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
- **A local-only dataset is verified against the local copy.** With
  `offsite = false` there is no remote, so the run finishes with the same scoped
  `rclone check --one-way --checksum --files-from <changed>` but source → local
  mirror instead. The `BACKUP-FAILED` marker therefore keeps meaning "the mirror
  was verified" on every dataset, offsite or not.
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
| `/var/backup/<Name>/BACKUP-LAST-SUCCESS` | last run that verified the mirror, or found nothing to verify; the freshness timer watches its mtime |
| `/var/lib/backup/rclone.conf` | Proton remote config, mode 0600, **runtime only — never in the Nix store** |
| `/var/lib/github-mirrors/<owner>_backup/<repo>` | ghorg bare git mirrors, refreshed in place (Disk 1) |
| `/var/backup/GitHub/current` | local mirror of the GitHub mirrors (Disk 2) |
| `/run/lock/media-backup.lock` | driver-owned lock, mode 0600, serializing the datasets that share the one Proton credential; local-only datasets take `/run/lock/media-backup-<name>.lock` instead |
| `/run/backup-watch/<name>/` | request queue for a dataset with `onChange` enabled: the watcher creates a file per debounced batch, and the backup unit drains it |

Proton paths are the dataset name under the remote: `proton:<Name>` — on
smortress, `proton:Photos`, `proton:Videos`, `proton:Music`, `proton:GitHub`,
and `proton:CloudflareTofu`.

## Datasets on smortress

| Name | Driver | Source | Schedule | Trigger | Full check | Offsite | preBackup |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `Photos` | restic | `/var/lib/media/Photos` | 03:00 | `onChange` (15m) | Sun 06:00 | yes (`proton:restic/Photos`) | generated `pg_dump --clean --if-exists` into the restic staging directory |
| `Videos` | rclone | `/var/lib/media/Videos` | 01:00 | `onChange` (15m) | Sun 07:00 | yes | — |
| `Music` | rclone | `/var/lib/media/Music` | 05:00 | `onChange` (15m) | Sun 08:00 | yes | — |
| `GitHub` | rclone | `/var/lib/github-mirrors` | 00:30 | timer only | Sun 10:00 | yes | `ghorg` refresh of the `smores56` mirrors (see below) |
| `CloudflareTofu` | rclone | `/var/lib/cloudflare-tofu` | 00:15 | timer only | — | yes | — |

Every dataset excludes `/.cache/**`, `**/.cache/**` and `/rclone.conf` by
default (the `excludes` option default). That keeps regenerable caches (at the
source root and nested) and a stray `rclone.conf` at the source root out of
the backup — it does **not** make the backup secret-free: a credential-shaped
file anywhere else (e.g. `Photos/backup/rclone.conf`, a `.env`) is copied unless
you add it to `excludes`. Both cache patterns are needed for rclone: its `**/`
requires a preceding path segment, so it misses a `.cache` sitting at the
source root. `Photos` additionally excludes `/thumbs/**` and
`/encoded-video/**` — regenerable Immich derived assets that Immich rebuilds
from the originals, so they need not occupy a backup.

## Photos: restic driver

Photos uses `driver = "restic"`; the units are generated by
[`backup-restic.nix`](../../nixos/backup-restic.nix), not by the rclone driver.
The other datasets are unchanged until their own migration.

| Path | What |
| --- | --- |
| `/var/lib/media/Photos` | live Immich library (Disk 1), copied into the repository |
| `/var/backup/restic/Photos` | local restic repository (Disk 2); `restic mount` gives a browsable view |
| `/var/lib/backup/restic-staging/photos/immich.sql.gz` | generated `pg_dump --clean --if-exists -d immich \| gzip`, included in every snapshot |
| `/var/backup/Photos/BACKUP-FAILED` | failure marker (detailed from the hook, generic from `ExecStopPost`) |
| `/var/backup/Photos/BACKUP-LAST-SUCCESS` | last backup that passed the local check and the Proton copy/check |
| `proton:restic/Photos` | append-only byte copy of the repository (never synced, never pruned) |
| `/run/secrets/restic-password` | restic password, root-only 0400, read at run time |
| `/run/lock/media-backup.lock` | host-wide lock held by the whole run, including the Proton copy |
| `/run/backup-watch/photos/` | watcher request queue; `/run/backup-watch/photos.running` marks an active run |

Units: `backup-photos.service` + `.timer` (03:00 daily, 15m randomized),
`backup-photos-fullcheck.service` + `.timer` (Sunday 06:00,
`restic check --read-data-subset=10%`), `backup-photos-dump.service` (runs as
`postgres`, `UMask=0077`, writes the gzipped SQL dump atomically),
`backup-photos-watch.service` (shell `inotifywait` watcher) and
`backup-photos-queue.path` (`DirectoryNotEmpty`).

A run holds the host lock and executes `resticprofile backup`, which:

1. runs the retention rule (7 daily / 8 weekly / 24 monthly / 3 yearly,
   prune) locally;
2. in `run-after` (only after success), runs `restic check`, copies the
   repository to
   `proton:restic/Photos` with `rclone copy`, verifies it with
   `rclone check --one-way`, writes `BACKUP-LAST-SUCCESS` atomically and
   removes `BACKUP-FAILED`;
3. on failure, `run-after-fail` removes the success marker and writes
   `BACKUP-FAILED`; a timeout or resticprofile lock failure skips the hook, so
   `ExecStopPost` writes the generic marker instead.

`rclone copy` (never `sync`) means a local prune does not delete Proton files;
stale repository files there are harmless and the local repository remains the
authoritative restore source. `rclone check --one-way` only requires local
repository files to exist remotely, so leftover remote packs do not fail a run.
Hooks pass explicit `--repo`/`--password-file` because resticprofile does not
export them to hook commands.

Immich's built-in scheduled dumps stay enabled; they are a fast local restore
path and are not part of the offsite copy. The restic dump is the documented
drill format (plain SQL), so a restore uses `psql`, not `pg_restore`.

### Restoring Photos

**Local repository (backup disk available).** Restore the newest snapshot, then
rebuild the database:

```sh
restic -r /var/backup/restic/Photos --password-file /run/secrets/restic-password \
  restore latest --target /restore
# /restore/var/lib/media/Photos is the library;
# /restore/var/lib/backup/restic-staging/photos/immich.sql.gz is the database dump.
```

**Proton copy (local disk lost).** Copy the byte copy back into a local
directory, then restore from it. Run it under the host lock because it uses the
same Proton credential:

```sh
flock /run/lock/media-backup.lock rclone copy proton:restic/Photos /restore/restic-Photos \
  --config /var/lib/backup/rclone.conf --transfers 8 --checkers 16
restic -r /restore/restic-Photos --password-file /run/secrets/restic-password check
restic -r /restore/restic-Photos --password-file /run/secrets/restic-password \
  restore latest --target /restore
```

**Database.** The dump is plain SQL in Immich's documented shape (including
`search_path` handling). Restore it as `postgres` into an empty database:

```sh
gunzip -c /restore/var/lib/backup/restic-staging/photos/immich.sql.gz \
  | runuser -u postgres -- psql -v ON_ERROR_STOP=1 -d immich
```

Run the drill in [`drills/restore-drill.sh`](./drills/restore-drill.sh) for the
rclone datasets; the restic drill and escrowed-key-only restore land in T10.

> The `restic-password` sops key is not yet in `secrets/smortress.yaml`. Add it
> (root-only, 0400) and deploy `/run/secrets/restic-password` before the first
> scheduled run; without it every restic unit fails and raises the alert.

## GitHub repo mirror

`githubBackup` mirrors this host's GitHub repos onto the backup disk as
bare git mirrors, driven by
[`modules/nixos/github-backup.nix`](../../nixos/github-backup.nix). GitHub
remains the authoritative copy; the HDD mirror provides fast local restore and
protection against an accidental repo deletion or account lockout, and the
dataset is also copied to Proton (`offsite = true`). The first offsite seed is
large; later runs move only the ref files ghorg rewrote plus any new packs.
Measured deltas range from 213 small ref/config files (35 KiB, no new objects)
to 45–52 files (2.2–2.6 MiB) when fetches bring objects. No periodic
`git repack` runs, so packs are not rewritten and the copy-based mirror does
not re-upload unchanged data.

- **Refresh.** The dataset's `preBackup` runs
  [`github-mirror.sh`](./github-mirror.sh) under [`gitconfig`](./gitconfig) via
  `GIT_CONFIG_GLOBAL`: [ghorg](https://github.com/gabrie30/ghorg)
  `clone --backup --clone-wiki --skip-forks` of `user.githubUser`, which
  clones on the first run and `git remote update`s thereafter, plus
  `GHORG_FETCH_GIT_LFS=true` so LFS objects are pulled. Archived repos **are**
  mirrored (they are frozen, not disposable — most of this owner's history is
  archived); forks are skipped by policy, so a fork carrying unique commits is
  not backed up.
  `fetch.unpackLimit=1` stores every fetch as a pack instead of exploding it
  into loose objects, and auto-maintenance is disabled (`maintenance.auto=false`)
  so git does not rewrite packs behind the copy's back. The mirror therefore
  gains one pack per fetch that brought objects; a periodic `repack` would bound
  the count but re-copy every pack, so it is deliberately not run.
- **Token.** Read at runtime from `githubBackup.tokenFile`
  (`/run/secrets/github-repo-pat`, a classic `repo`-scoped sops secret,
  root-owned mode 0400); never placed in the Nix store. This is a *different*
  token from the `github-key-pat` `bootstrap` uses for SSH-key registration.
  Classic `repo` grants write access to every repo the account can reach; the
  mirror only reads, and fine-grained tokens cannot read wikis. ghorg embeds
  the token in the `git clone`/`git remote set-url` URL, so it is visible in
  root argv during a run (see the hardening list).
- **Private-repo guard.** `githubBackup.probeRepo` names a known-private
  repo; the run fails unless that repo was refreshed in the current run. A token
  that lost `repo` scope still lists public repos and exits 0, and ghorg never
  prunes the private mirrors it created earlier, so a directory-existence check
  would pass forever. The script compares the probe's `FETCH_HEAD` mtime against
  a marker taken before ghorg ran.

## How a run works

1. `preBackup` (if set) runs first, outside the host lock, with `BACKUP_DATE`,
   `BACKUP_CURRENT`, `BACKUP_SOURCE` in the environment. Writes are atomic
   (`.tmp` + `mv`), and a killed dump traps and removes its `.tmp` so no partial
   file is mirrored. A producer-style preBackup (ghorg) can run for hours
   without blocking the media units. The source's emptiness check runs *after*
   `preBackup`, so a dataset whose `preBackup` creates the source is not
   rejected for starting empty.
2. The driver takes the lock for the dataset (created mode 0600): the shared
   `/run/lock/media-backup.lock` for offsite datasets — Proton refresh tokens are
   single-use, so two concurrent rclone clients would blank the session
   (rclone#9880) — and `/run/lock/media-backup-<name>.lock` for local-only ones.
   A queued dataset simply waits. Manual `backup` runs and the restore drill take
   the same lock.
3. Local copy → `current/`, overwritten revisions to `versions/<date>/`.
4. Offsite copy → `proton:<Name>` with
   `--protondrive-replace-existing-draft=true` (uploads only; never used to
   delete).
5. Verify the mirror: `rclone check --checksum --one-way` scoped with
   `--files-from` to the paths the copy wrote this run, or skipped entirely when
   it wrote nothing. Offsite datasets check local↔remote; a local-only dataset
   (`offsite = false`) checks source↔local instead. A `--full-check` run
   (per-dataset `fullCheckSchedule`) walks the whole mirror instead.
6. On success the unit is done. On failure the driver writes a detailed
   `BACKUP-FAILED` marker from inside the run; if the run was killed before that
   could happen, `ExecStopPost` writes a generic one (it never overwrites the
   detailed marker). `onFailure` sends the Cloudflare email alert
   (`cloudflare-email@%n.service`).

`TimeoutStartSec` (per-dataset `timeout`) is a wall-clock backstop only; a stuck
run is normally caught by `stallTimeout` in ~30m. A `TimeoutStartSec` kill
cannot run the in-process marker, which is why the marker is in `ExecStopPost`.

## Event-driven trigger (optional)

A dataset with `onChange.enable = true` gets a long-running
`backup-<name>-watch.service` in addition to its timer. It runs
[`backup_watch.py`](./backup_watch.py) for rclone datasets and
[`backup_watch.sh`](./backup_watch.sh) for restic datasets, both streaming
recursive inotify events from the source (`inotifywait -m -r`,
`create`/`close_write`/`moved_to`), waiting for the dataset's
`onChange.debounce` of quiet, then creating one request file in
`/run/backup-watch/<name>/`. The shell watcher checks
`/run/backup-watch/<name>.running` (created by the backup unit while it runs)
and labels the batch as a follow-up, which is the same request either way. A
`backup-<name>-queue.path` unit watching that
directory with `DirectoryNotEmpty=` starts the ordinary
`backup-<name>.service`; the watcher never runs the driver, so the unit's
timeout, failure marker, Cloudflare email alert, and sandbox stay in one place.

- **Debounce.** After the last accepted change, nothing is queued until the
  quiet period (15m on smortress) elapses, so a photo import or music sync
  produces one run instead of one per file. Photos runs `pg_dump` on every
  invocation, which is the main reason the window is not shorter.
- **Coalescing.** The queue is drained by the backup unit's privileged
  `ExecStartPre`, and `DirectoryNotEmpty` is re-checked when the service exits.
  Changes that arrive during a run therefore leave a request behind and cause
  exactly one follow-up run — never a lost change and never a run per event.
- **Noise filter.** Hidden path components, writer scratch suffixes (`.part`,
  `.tmp`, `.swp`, `.!qB`, …), and `Thumbs.db`/`desktop.ini` are ignored
  everywhere. `onChange.ignore` adds per-dataset globs matched against each path
  component, so Photos passes `["thumbs" "encoded-video"]` and a change inside
  Immich's regenerable derived trees does not trigger a backup.
- **The timer is still the guarantee.** The nightly schedule remains, and it is
  the fallback for anything the watcher can miss: events before the watches were
  installed, an inotify queue overflow, or a watcher restart (`Restart=always`,
  10s). The watcher is skipped, not restarted in a loop, while the source
  directory does not exist (`ConditionPathIsDirectory`).


## Restoring rclone datasets

**Files, from the local mirror.** The mirror is a plain directory tree:

```sh
rsync -a /var/backup/Music/current/ /restore/Music/
```

**Files, from offsite** (local disk lost):

```sh
rclone copy proton:Music /restore/Music \
  --config /var/lib/backup/rclone.conf --transfers 8 --checkers 16
```

Photos is no longer restored this way; see
[Restoring Photos](#restoring-photos).

Add `--backup-dir`-style recovery by reaching into the same path's local
`versions/` if the mirror still exists.

**Database (Photos).** The newest dump is in `current/db/`. It sits behind the
`0700` backup directory, so the `postgres` user cannot open the path directly —
run this as root and let root stream the file in:

```sh
runuser -u postgres -- createdb -O postgres restored
runuser -u postgres -- pg_restore --no-owner -d restored \
  < /var/backup/Photos/current/db/immich.dump
```

(To restore from an unprivileged shell, copy the dump somewhere `postgres` can
read first: `install -m 644 …/immich.dump /tmp/immich.dump`.)

**GitHub repos.** The mirror is a tree of bare mirrors. To restore one:

```sh
# clone a working tree straight out of the mirror
mkdir -p /restore/<repo> && cd /restore/<repo> && git init
# source the bare mirror as a remote, or clone it directly:
#   git clone /var/backup/GitHub/current/<owner>_backup/<repo> /restore/<repo>
git remote add origin /var/backup/GitHub/current/<owner>_backup/<repo>
git fetch origin && git checkout main
```

To push a mirror back to a remote, `git push --mirror <url>` from it.

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
backup.datasets.Books = {
  # driver = "restic";  # default "rclone"; restic needs repository/passwordFile
  schedule = "*-*-* 07:00:00";
  # fullCheckSchedule = "Sun *-*-* 06:00:00";  # extra whole-mirror / read-data check
  # timeout = "12h";       # wall-clock backstop
  # offsite = false;       # local-only dataset
  # stallTimeout = "30m";  # rclone only; "0" disables; otherwise must be >= 60s
  # excludes = [ "/.cache/**" "**/.cache/**" "/rclone.conf" ];  # defaults; override to add more
  # postgres = true;       # generated dump unit (rclone: current/db; restic: staging)
  # preBackup = '' ... ''; # rclone only: runs with BACKUP_* env, before the copy
  # repository = "/var/backup/restic/Books";  # restic default
  # protonPath = "restic/Books";               # restic default
  # passwordFile = "/run/secrets/restic-password";  # restic default
  # retention = { daily = 7; weekly = 8; monthly = 24; yearly = 3; };  # restic defaults
  # check = true;          # restic: check after backup + fullCheckSchedule read-data check
};
```

The source defaults to `/var/lib/media/<Name>`; set `source` to override. A
dataset needs `backup.enable = true` (the backup disk).

## Known limits

- **restic driver (Photos).** The Proton copy re-reads the whole local
  repository for `rclone check` on every run, which is slower than the rclone
  driver's changed-files-only check. A killed run can leave a restic lock;
  clear it with `restic -r /var/backup/restic/Photos --password-file
  /run/secrets/restic-password unlock`. There is no stall watchdog: a wedged
  Proton upload is bounded by the dataset's `timeout` (`TimeoutStartSec`) and
  resticprofile retries no step by itself. Proton quota is not monitored; a
  failed copy raises `BACKUP-FAILED` and the email alert. The dump staging file
  is overwritten every run, so `restic` keeps the previous version only through
  snapshots.
- A kill that lands *after* rclone has committed a file but before it reports
  can leave a retry that re-uploads a zero-byte file; this is not data loss
  (the source and local mirror are intact) but it is not self-healing. Tracked
  as a known low-severity finding.
- The offsite mirror never prunes and keeps no versions: a file deleted from the
  source lives on in Proton forever, and a changed file is overwritten in place.
  That is deliberate for backup safety; there is no automated retention/prune
  tooling. For the deliberate one-off, see
  [Pruning a mirror](#pruning-a-mirror-one-time).
- `immich.backup` and the old restic/Immich-specific pipeline have
  been removed; these generic datasets replace them.
- The offsite copy logs each copied filename at INFO (to extract changed paths),
  so source filenames reach journald on every run that copies files — previously
  they were suppressed at NOTICE. journald is root-only and local.
- The `--files-from` list is a 0600 temp file removed in a `finally`; a hard kill
  (systemd `TimeoutStartSec`, OOM) can leave it in `$TMPDIR`.
- A `fullCheckSchedule` run re-runs the whole dataset — `preBackup` (an extra
  `pg_dump` for Photos) and both copies — not only the check.
- The GitHub mirror is append-only like every other dataset: `copy` never
  deletes, so a repo removed from GitHub lingers in
  `/var/backup/GitHub/current`. `--skip-forks` also keeps forks out of the
  *listing*, so one forked before the first run is never mirrored — a deliberate
  scope choice, not a silent error. Archived repos are included.

### Hardening not yet done (accepted, from the final review)

- The backup service runs as root with no `ProtectSystem`/`ReadWritePaths`
  (it does set `NoNewPrivileges`, `PrivateTmp`, `ProtectHome`, kernel/clock/
  hostname protections, and address-family restrictions); it feeds source
  filenames through rclone, so a parser/write flaw would be uncontained.
- ghorg puts the GitHub token in the `git` argv (`clone`/`remote set-url`), which
  any local user can read from `/proc/<pid>/cmdline` during a run; the wrapper
  strips a token left in a mirror's config before the copy, and the token is
  root-only, but the argv window remains.
- A mirrored repo can set `lfs.url` in `.lfsconfig`, redirecting the root-run LFS
  fetch to an arbitrary endpoint (blind SSRF). git-lfs ignores unsafe keys, so
  this is not code execution.
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
- Offsite datasets check local↔remote, never source↔local; source-side
  under-copy is only caught by the manual drill's sample. Local-only datasets
  (`offsite = false`, none on smortress today) check source↔local instead,
  scoped to the files copied that run; the weekly full check walks the whole
  tree.
- The restore drill restores the newest dump as the `postgres` superuser, so a
  dump shaped via a compromised Immich DB executes as that user.
- The drill is only syntax-checked in CI (not run); it scrapes the unit's
  `ExecStart` via `xargs` (quote-lossy) and ignores a custom `mountPoint`.
- `--timeout` (driver, non-rclone steps) defaults to 12h and is not forwarded
  from the dataset option — systemd `TimeoutStartSec` is the real bound.
- The failure marker embeds raw rclone output and is unbounded; the lock file is
  created but never re-hardened against a pre-existing looser mode.
