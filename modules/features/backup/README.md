# Backup — restic plus the GitHub mirror

restic is the backup driver: one job covers the whole durable tree, and every
repo is encrypted client-side.

| Piece | Where |
| --- | --- |
| Repo targets, schedule, retention | [`modules/nixos/restic-backup.nix`](../../nixos/restic-backup.nix) |
| The local encrypted disk (mount + LUKS) | [`modules/nixos/backup.nix`](../../nixos/backup.nix) |
| GitHub mirror units and scripts | [`modules/nixos/github-backup.nix`](../../nixos/github-backup.nix) |
| Failure email | [`modules/nixos/alerting.nix`](../../nixos/alerting.nix) |
| Operator steps (disk format, secrets, restore drill) | [`docs/manual-steps.md`](../../../docs/manual-steps.md) |

## Repos and what they hold

Two repos, same snapshots, one source path:

| Repo | Target |
| --- | --- |
| `r2` | `s3:https://<account>.r2.cloudflarestorage.com/restic-backup`, credentials from the sops-rendered `restic-r2.env` |
| `local` | `/var/backup/restic`, on the LUKS-encrypted backup disk |

- **One source:** `/var/lib/data` — the whole durable tree: the brain/vault
  tree, wallpapers, books/music/photos, the memory export, the GitHub
  mirrors, and Open WebUI state. There are no excludes inside the tree.
- **Password:** `sops.secrets.restic-password` (`/run/secrets/restic-password`),
  the same key for both repos. Losing it means losing both repos.
- **Schedule:** nightly at 03:30 with up to 15 minutes of random delay
  (`Persistent`, so a host that was off catches up). Only `r2` sets
  `initialize = true`, because a fresh bucket is expected; the `local` repo is
  created once by hand (below).
- **Retention:** `forget --prune` with `--keep-daily 14 --keep-weekly 8
  --keep-monthly 12`.
- **Integrity:** `runCheck = true` runs `restic check` after every backup.
- **Database dump:** `restic-db-dump` runs as `postgres` and writes
  `/var/lib/data/db/immich.dump` (`pg_dump -Fc --no-owner`, written to a temp
  file and renamed). The Immich database is the library's source of truth, so
  the dump has to exist inside the tree. Both repos `wants` it rather than
  `requires`, so a stopped database delays no backup but still alerts.
- **Failure alerting:** both generated units (`restic-backups-r2`,
  `restic-backups-local`) carry `onFailure = cloudflare-email@%n.service`, so a failed nightly run mails its own journal. There
  is no independent freshness timer, so a silent host or a stopped timer is not
  alerted on.

The backup disk must be mounted before a run: `/var/backup` is mounted `nofail`, and restic's unit fails loudly (and
alerts) if it is missing.

## Operating restic

Commands, the restore drill and the disk format are in [`docs/manual-steps.md`](../../../docs/manual-steps.md) ("Backup (restic)").

### First run on a new backup disk

The `local` repo is deliberately **not** initialised by the module. With
`initialize = true`, an empty-but-mounted `/var/backup` (a freshly formatted
filesystem, or the wrong disk) would quietly become a new repo and the run would
report success, hiding a lost backup disk. Instead the first run fails, which
fires the `onFailure` alert; create the repo once, on a disk you have just
verified is the right one:

```sh
lsblk -f /var/backup          # the encrypted disk's filesystem, mounted, empty
sudo restic-local init
sudo systemctl start restic-backups-local.service
```

`r2` initialises itself: an empty bucket is expected there.

## GitHub mirror and metadata

`githubBackup` (smortress only) keeps a mirror of this host's GitHub
repos and the metadata GitHub holds outside git. GitHub remains the
authoritative copy; the mirror lives inside `/var/lib/data`, so restic carries
it with everything else and there is no separate offsite leg.

Layout under `/var/lib/data/github-mirrors`:

| Path | Contents |
| --- | --- |
| `<owner>_backup/<repo>` | ghorg bare mirror, wiki repo, LFS objects, one pack per fetch |
| `meta/repositories/<repo>/` | pgb JSON: `issues/<n>.json`, `pulls/<n>.json`, comments/events/reviews/commits, labels, milestones, discussions, releases+assets, attachments, security advisories, plus per-resource `last_update` checkpoints |
| `manifests/<date>/` | `repos.txt` (repo sets), `counts.json` (repo/issue/PR counts, mismatches, fsck sample), `run.log` |

Units the module owns:

- **`github-mirror.service` + `.timer`** — nightly at `schedule` (`modules/nixos/github-backup.nix`)
  (00:30, `Persistent=true`), one oneshot. It runs the chain
  [`github-mirror.sh`](./github-mirror.sh) →
  [`github-metadata.sh`](./github-metadata.sh) →
  [`github-verify.sh`](./github-verify.sh) under [`gitconfig`](./gitconfig)
  (`GIT_CONFIG_GLOBAL`), as root with the hardened sandbox below. A failure
  mails through `onFailure`.
- **`github-metadata-full.service` + `.timer`** — the monthly non-incremental
  metadata pass (first Sunday 09:00). pgb runs **without** `-i` into `meta.new`,
  verifies it, carries the live `last_update` checkpoints forward, and swaps
  `meta.new` over `meta` while holding `/run/lock/github-metadata.lock`; on any
  failure the live `meta` is untouched and the staging tree is removed.

Both units run as root with `ProtectSystem=strict`, `ProtectHome`,
`PrivateTmp`, `NoNewPrivileges`, restricted address families/namespaces, and the
only write paths `mirrorRoot` and `/run/lock`. `UMask=0077` plus the
`0700` tmpfiles rule on `mirrorRoot` keep private repo contents out of other
users' reach.

- **Refresh.** [ghorg](https://github.com/gabrie30/ghorg)
  `clone --backup --clone-wiki --skip-forks` of `user.githubUser` clones on the
  first run and `git remote update`s thereafter, with `GHORG_FETCH_GIT_LFS=true`
  so LFS objects are pulled. Archived repos **are** mirrored; forks are skipped
  by policy. `fetch.unpackLimit=1` stores every fetch as a pack and
  `maintenance.auto=false` stops git rewriting packs behind the mirror's back,
  so a run adds one pack per fetch that brought objects.
- **Metadata.** [python-github-backup](https://github.com/josegonzalez/python-github-backup)
  runs with `-P -i` into `meta`: issues, comments/events, pulls,
  reviews/commits, labels, milestones, discussions, releases and assets,
  attachments, and security advisories. `-i` uses pgb's per-repo `last_update`
  checkpoints and only fetches what changed.
- **Verification.** [`github-verify.sh`](./github-verify.sh) fails the run if
  the ghorg repo set differs from `gh api --paginate user/repos` (forks
  excluded, archived included), pgb's repo set differs from the mirror set,
  issue/PR counts drift from GraphQL by more than `GITHUB_COUNT_DRIFT` (default
  5 per repo), an incremental run left a `last_update` checkpoint older than
  that run's marker, or a sample (`GITHUB_FSCK_SAMPLE`, default 5) of mirrors
  fails `git fsck --full`. Evidence lands in `manifests/<date>/` even on
  failure.
- **Token.** Read at runtime from `tokenFile` (`modules/nixos/github-backup.nix`)
  (`/run/secrets/github-repo-pat`, a classic `repo`-scoped sops secret,
  root-owned). ghorg embeds it in the `git clone`/`remote set-url` URL, so it is
  visible in root argv during a run; pgb and gh receive it as a file path and an
  environment variable. It is never placed in the Nix store.
- **Private-repo guard.** `githubBackup.probeRepo` names a known-private repo;
  the run fails unless that repo was refreshed in the current run (its
  `FETCH_HEAD` mtime is newer than a marker taken before ghorg ran). A token
  that lost `repo` scope still lists public repos and exits 0, and ghorg never
  prunes earlier mirrors, so an existence check would pass forever.

### Restoring from the mirror

```sh
# clone a working tree straight out of the mirror
git clone /var/lib/data/github-mirrors/<owner>_backup/<repo> /restore/<repo>
```

Metadata is plain JSON under `meta/repositories/<repo>/`; `manifests/<date>/`
records what the verified run covered.
