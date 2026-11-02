# Backup — restic plus the GitHub mirror

restic is the backup driver. It replaces the old rclone dataset driver: one job
covers the whole durable tree, and every repo is encrypted client-side.

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
  ciphertext, wallpapers, books/music/photos, the memory export, the GitHub
  mirrors, Radicale and Open WebUI state. There are no excludes inside the
  tree.
- **Password:** `sops.secrets.restic-password` (`/run/secrets/restic-password`),
  the same key for both repos. Losing it means losing both repos.
- **Schedule:** nightly at 03:30 with up to 15 minutes of random delay
  (`Persistent`, so a host that was off catches up); `initialize = true`, so a
  fresh repo is created on the first run.
- **Retention:** `forget --prune` with `--keep-daily 14 --keep-weekly 8
  --keep-monthly 12`.
- **Integrity:** `runCheck = true` runs `restic check` after every backup.
- **Database dump:** `restic-db-dump` runs as `postgres` and writes
  `/var/lib/data/db/immich.dump` (`pg_dump -Fc --no-owner`, written to a temp
  file and renamed). The Immich database is the library's source of truth, so
  the dump has to exist inside the tree. Both repos `wants` it rather than
  `requires`, so a stopped database delays no backup but still alerts.
- **Failure alerting:** both generated units (`restic-backups-r2`,
  `restic-backups-local`) carry `onFailure = cloudflare-email@%n.service` when
  `alerting.enable` is on, so a failed nightly run mails its own journal. There
  is no independent freshness timer: the dataset driver's
  `backup-freshness` check is gone, and a silent host or a stopped timer is not
  alerted on.

The backup disk must be mounted before a run: `backup.mountPoint`
(`/var/backup`) is mounted `nofail`, and restic's unit fails loudly (and
alerts) if it is missing.

## Operating restic

The NixOS module installs one wrapper per repo with the repository, password
file and R2 credentials already in the environment:

```sh
sudo restic-r2 snapshots          # or restic-local
sudo restic-r2 stats latest
sudo journalctl -u restic-backups-r2 -n 100
systemctl list-timers 'restic-*'
```

A manual run is the same unit the timer starts:

```sh
sudo systemctl start restic-backups-local.service
```

`restic-r2`/`restic-local` write nothing beyond the repo they name; they are the
supported way to inspect and restore, because they cannot forget the credential
file or the repository URL.

### Restore drill

The procedure, with the exact commands and the assertion to make, is in
[`docs/manual-steps.md`](../../../docs/manual-steps.md) ("Restore drill"). In
short, per repo:

```sh
sudo restic-r2 restore latest --target /var/tmp/restore \
  --include /var/lib/data/wallpapers
sha256sum /var/tmp/restore/var/lib/data/wallpapers/<file> \
  /var/lib/data/wallpapers/<file>
sudo restic-r2 check --read-data-subset=2%
```

A restore that reads a subset and a `check` over a sample of packs proves both
that the snapshot is complete and that its data is readable. Do it for `r2` and
for `local`; both were drilled before the rclone driver was retired.

## GitHub mirror and metadata

`githubBackup` (enabled on smortress only) keeps a mirror of this host's GitHub
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

- **`github-mirror.service` + `.timer`** — nightly at `githubBackup.schedule`
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
- **Token.** Read at runtime from `githubBackup.tokenFile`
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

## Files here

| File | Role |
| --- | --- |
| `github-mirror.sh` | ghorg refresh with the probe and environment guards |
| `github-metadata.sh` | python-github-backup driver (incremental, full, swap) |
| `github-verify.sh` | repo set, count drift, checkpoint and fsck verification |
| `gitconfig` | the `GIT_CONFIG_GLOBAL` that pins packing and disables auto-maintenance |

## Checks

- `github-metadata` — pgb flags and token-by-file, manifest counts,
  stale/scope/count failures, and the full-pass swap.
- `github-mirror-probe` — a stale private-repo probe is rejected and a
  token-bearing origin is scrubbed.

restic itself has no shell surface to unit-test; the restore drill in
`docs/manual-steps.md` is the acceptance test, run against both repos.
