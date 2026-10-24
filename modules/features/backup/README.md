# Backup — rclone driver (media and GitHub to Proton)

**Format policy.** Every dataset is a plain rclone tree: Disk 1 is the source,
Disk 2 holds a `current/` copy plus local `versions/` (`--backup-dir`), and
Proton gets an append-only copy. The Proton Drive app is the phone/desktop
access path to those trees. `copy`, never `sync`: the backup never
propagates source deletions, `versions/` lives only on the local disk, Proton
keeps every version ever copied, and there is no encryption, key, or
repository layer to manage beyond that.

Generic, dataset-agnostic backup driver, [`backup.sh`](./backup.sh) — a small
shell script packaged with `writeShellApplication`. One systemd oneshot + timer
per `backup.datasets.<Name>` entry, optionally fired early by a filesystem
watcher (`onChange`). A dataset is a directory on Disk 1, a local mirror on the
backup disk (Disk 2), and — unless `offsite` is disabled — an append-only mirror
on Proton Drive (Disk 3, "offsite"). Three dataset families use it: the media
trees (`Photos`, `Videos`, `Music`; offsite and change-triggered), a GitHub
repo mirror (`GitHub`; see [GitHub repo mirror and metadata](#github-repo-mirror-and-metadata)), and the
OpenTofu edge state (`CloudflareTofu`).

The rationale for every destructive-looking choice lives as a comment next to
the code in [`backup.sh`](./backup.sh). This file is the operator's view.

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
  `rclone check --checksum --one-way --files-from0 <those paths>`, so only what
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
  `rclone check --one-way --checksum --files-from0 <changed>` but source → local
  mirror instead. The `BACKUP-FAILED` marker therefore keeps meaning "the mirror
  was verified" on every dataset, offsite or not.
- **A run that stalls is killed and retried.** rclone's own idle timeout does
  not catch a wedged upload session (one such hang held the shared Proton lock
  for 18h). A stats-based watchdog (`stallTimeout`, default 30m) samples the
  step log and aborts a step whose `Transferred:` *and* `Checks:` counters stop
  advancing, then retries — `copy` is resumable. A non-zero `stallTimeout` must
  be at least 60s (two 30s rclone stats intervals) or evaluation fails; `"0"`
  disables the watchdog.

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
smortress, `proton:Photos`, `proton:Videos`, `proton:Music`, `proton:LobeChat`,
`proton:RustFS`, `proton:GitHub`, and `proton:CloudflareTofu`.

## Datasets on smortress

| Name | Source | Schedule | Trigger | Full check | Offsite | preBackup |
| --- | --- | --- | --- | --- | --- | --- |
| `Photos` | `/var/lib/media/Photos` | 03:00 | `onChange` (15m) | Sun 06:00 | yes | `pg_dump -Fc` of `immich` into `current/db/immich.dump` |
| `Videos` | `/var/lib/media/Videos` | 01:00 | `onChange` (15m) | Sun 07:00 | yes | — |
| `Music` | `/var/lib/media/Music` | 05:00 | `onChange` (15m) | Sun 08:00 | yes | — |
| `LobeChat` | `/var/lib/lobechat` | 02:00 | timer only | Sun 10:00 | yes | `pg_dump -Fc` of `lobechat` into `current/db/lobechat.dump` |
| `RustFS` | `/var/lib/rustfs` | 04:00 | timer only | Sun 11:00 | yes | — |
| `GitHub` | `/var/lib/github-mirrors` | 00:30 | timer only | Sun 10:00 | yes | `ghorg` refresh, then incremental `python-github-backup` metadata + verification (see below) |
| `CloudflareTofu` | `/var/lib/cloudflare-tofu` | 00:15 | timer only | — | yes | — |

`RustFS` also excludes its derived caches and temporary tree
(`/.rustfs.sys/tmp/**`, `/.rustfs.sys/buckets/.usage*`,
`/.rustfs.sys/buckets/.bloomcycle.bin`,
`/.rustfs.sys/buckets/.scanner-pause-backlog.json`): RustFS rewrites them
continuously and rebuilds them on start, so a live mirror can never be
point-in-time for them, and sampling one in the restore drill is flaky by
construction.

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

## GitHub repo mirror and metadata

`githubBackup` mirrors this host's GitHub repos onto the backup disk as
bare git mirrors plus a metadata tree, driven by
[`modules/nixos/github-backup.nix`](../../nixos/github-backup.nix). GitHub
remains the authoritative copy; the HDD mirror provides fast local restore and
protection against an accidental repo deletion or account lockout, and the
dataset is also copied to Proton (`offsite = true`). The first offsite seed is
large; later runs move only the ref files ghorg rewrote plus any new packs and
metadata files.
Measured git deltas range from 213 small ref/config files (35 KiB, no new
objects) to 45–52 files (2.2–2.6 MiB) when fetches bring objects. No periodic
`git repack` runs, so packs are not rewritten and the copy-based mirror does
not re-upload unchanged data.

Layout under `/var/lib/github-mirrors` (the dataset source):

| Path | Contents |
| --- | --- |
| `<owner>_backup/<repo>` | ghorg bare mirror, wiki repo, LFS objects, one pack per fetch |
| `meta/repositories/<repo>/` | pgb JSON: `issues/<n>.json`, `pulls/<n>.json`, comments/events/reviews/commits, labels, milestones, discussions, releases+assets, attachments, security advisories, plus per-resource `last_update` checkpoints |
| `manifests/<date>/` | `repos.txt` (repo sets), `counts.json` (repo/issue/PR counts, mismatches, fsck sample), `run.log` |

- **Refresh (daily).** The dataset's `preBackup` runs
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
- **Metadata (daily, incremental).** After ghorg,
  [`github-metadata.sh`](./github-metadata.sh) runs
  [python-github-backup](https://github.com/josegonzalez/python-github-backup)
  with `-P -i` into `meta`: issues, issue comments/events, pulls, pull
  comments/reviews/commits/details, labels, milestones, discussions, releases
  and assets, attachments, and security advisories. `-i` uses pgb's per-repo
  `issues/last_update` and `pulls/last_update` checkpoints and only fetches
  what changed; deleted issues stay on disk (pgb never prunes). The nixpkgs pin
  (0.64.0) has no `--issue-timeline`; events and comments cover that history.
  Git and gists stay with ghorg — pgb is not asked to clone repositories.
- **Verification.** [`github-verify.sh`](./github-verify.sh) runs after every
  metadata pass and fails the whole GitHub preBackup if: the ghorg mirror repo
  set differs from `gh api --paginate user/repos` (forks excluded, archived
  included; ghorg's `<repo>.wiki` siblings are tied to their parent and not
  treated as API repos); the pgb repo set differs from the mirror set; issue/PR
  counts drift from GraphQL by more than `GITHUB_COUNT_DRIFT` (default 5 per
  repo, for
  time-of-check drift and issues deleted since pgb saw them); an incremental
  run left a `last_update` checkpoint older than that run's marker; or a sample
  (`GITHUB_FSCK_SAMPLE`, default 5) of bare mirrors fails `git fsck --full`.
  Evidence lands in `manifests/<date>/` even on failure.
- **Monthly full pass.** `github-metadata-full.service` (first Sunday 09:00,
  `Persistent=true`) runs pgb **without** `-i` into `meta.new`, verifies it,
  carries the live `last_update` checkpoints forward, and swaps `meta.new` over
  `meta` while holding the shared host lock. The pgb run itself shares
  `/run/lock/github-metadata.lock` with the daily pass, so the staging fetch
  does not block the media datasets; only the swap takes the host lock. On any
  failure the live `meta` is untouched and the staging tree is removed;
  `meta.new`/`meta.old` are excluded from the dataset copy in case a swap
  overlaps a run.
- **Token.** Read at runtime from `githubBackup.tokenFile`
  (`/run/secrets/github-repo-pat`, a classic `repo`-scoped sops secret,
  root-owned mode 0400); never placed in the Nix store. This is the only GitHub
  token on the host: `bootstrap` uses the device-code flow instead of a stored
  provisioning PAT.
  Classic `repo` grants write access to every repo the account can reach; all
  three tools only read, and fine-grained tokens cannot read wikis. ghorg embeds
  the token in the `git clone`/`git remote set-url` URL, so it is visible in
  root argv during a run (see the hardening list). pgb and gh receive it as a
  `file://` path and an environment variable respectively, so it never enters
  their argv.
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
   `--files-from0` to the paths the copy wrote this run, or skipped entirely when
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
[`backup_watch.sh`](./backup_watch.sh), which streams recursive inotify events
from the source (`inotifywait -m -r`, `modify`/`create`/`delete`/`move`/
`attrib`), waits for the dataset's `onChange.debounce` of quiet, then creates one
request file in `/run/backup-watch/<name>/`. A `backup-<name>-queue.path` unit
watching that directory with `DirectoryNotEmpty=` starts the ordinary
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


**Files, from the local mirror.** The mirror is a plain directory tree:

```sh
rsync -a /var/backup/Photos/current/ /restore/Photos/
```

**Files, from offsite** (local disk lost):

```sh
sudo flock /run/lock/media-backup.lock \
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

**GitHub metadata.** Issues, PRs, discussions, releases, and attachments are
JSON snapshots, not restorable state: GitHub has no issue-import API that
preserves numbers, comments, and cross-references. Treat them as archival — the
readable record of what existed at the last run. They live in
`/var/backup/GitHub/current/meta/repositories/<repo>/` (or `proton:GitHub`) and
are read directly with `jq`:

```sh
jq -r '.title, .body, (.comment_data[]?.body)' \
  /var/backup/GitHub/current/meta/repositories/sdlc/issues/170.json
jq -r '.title, .body' \
  /var/backup/GitHub/current/meta/repositories/sdlc/pulls/169.json
```

`manifests/<date>/counts.json` is the evidence that the snapshot matched
GitHub at run time; `repos.txt` lists which repos were in the API, mirror, and
metadata sets. Reconstructing a lost issue is a manual copy from the JSON.

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
dataset needs `backup.enable = true` (the backup disk).

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
- `immich.backup` and the old Immich-specific backup pipeline have
  been removed; these generic datasets replace them.
- The offsite copy logs each copied filename at INFO (to extract changed paths),
  so source filenames reach journald on every run that copies files — previously
  they were suppressed at NOTICE. journald is root-only and local.
- The `--files-from0` list lives in the run's private 0700 workspace, removed by
  an `EXIT` trap; a hard kill (systemd `TimeoutStartSec`, OOM) can leave that
  directory in `$TMPDIR`.
- A `fullCheckSchedule` run re-runs the whole dataset — `preBackup` (an extra
  `pg_dump` for Photos) and both copies — not only the check.
- The GitHub mirror is append-only like every other dataset: `copy` never
  deletes, so a repo removed from GitHub lingers in
  `/var/backup/GitHub/current`. `--skip-forks` also keeps forks out of the
  *listing*, so one forked before the first run is never mirrored — a deliberate
  scope choice, not a silent error. Archived repos are included.
- pgb metadata is append-only in the same way: an issue or PR deleted on GitHub
  stays in `meta/` until the monthly full pass replaces the tree. The count
  check tolerates that drift up to `GITHUB_COUNT_DRIFT` per repo.
- The GitHub full-check run at Sunday 10:00 runs `preBackup` again (ghorg + an
  incremental pgb pass + verification) and then re-reads both copies.

### Hardening not yet done (accepted, from the final review)

- The backup service runs as root with no `ProtectSystem`/`ReadWritePaths`
  (it does set `NoNewPrivileges`, `PrivateTmp`, `ProtectHome`, kernel/clock/
  hostname protections, and address-family restrictions); it feeds source
  filenames through rclone, so a parser/write flaw would be uncontained.
- ghorg puts the GitHub token in the `git` argv (`clone`/`remote set-url`), which
  any local user can read from `/proc/<pid>/cmdline` during a run; the wrapper
  strips a token left in a mirror's config before the copy, and the token is
  root-only, but the argv window remains. pgb receives `file://<token-file>` and
  gh receives `GH_TOKEN` in its environment, so neither widens that window; the
  environment is root-only like the file.
- The monthly full pass stages under `meta.new` inside the dataset source. The
  dataset excludes `meta.new`/`meta.old`, and the swap takes the host lock, but a
  hard kill between the two renames can leave the live `meta` as `meta.old`
  (recoverable by renaming it back); `meta.old` is deliberately not deleted by
  the failure trap.
- A mirrored repo can set `lfs.url` in `.lfsconfig`, redirecting the root-run LFS
  fetch to an arbitrary endpoint (blind SSRF). git-lfs ignores unsafe keys, so
  this is not code execution.
- The stall watchdog and unchecked-hash guard grep the step log, which includes
  source filenames; a file deliberately named to embed
  `Transferred:`/`Checks:`/`hashes could not be checked` can forge a stall or a
  spurious failure. The shell watchdog samples the log every 30s and only sees
  newline-terminated output, unlike the deleted Python driver's per-line watch.
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
  from the dataset option — systemd `TimeoutStartSec` is the real bound. (The
  preBackup step is bounded by `timeout --kill-after`, which kills its process
  group.)
- The failure marker repeats the failing command line (plus the last lines of a
  failed check's output) with control characters stripped; the lock file is
  created but never re-hardened against a pre-existing looser mode.
