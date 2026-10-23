# Manual steps

Everything here is an operator action: work the repo cannot do from Nix.
`checks.manual-steps-sync` derives the inventory from the configuration, so
`nix flake check` fails when an item below is missing an anchor, when an anchor
no longer exists in the config, or when this file still contains an unresolved
placeholder marker.

An anchor is an HTML comment on its own line:

```html
<!-- manual-step: <kind>/<id> -->
```

Kinds: `host`, `secret`, `provider`, `dataset`, `service`, `app`, `alert`.
Adding a host directory, sops key, Tofu provider or notification, backup
dataset, public service, flake app, or alert path means adding its anchor with
real instructions.

## Hosts

The host list comes from `modules/hosts/*/`.

### smortress

<!-- manual-step: host/smortress -->

The always-on server (NixOS, x86_64), and the only host that decrypts
`secrets/smortress.yaml`. Reinstall from a blank disk with:

```sh
nix run .#host-key -- smortress
nix run .#install -- smortress root@<target-ip>
```

`install` wipes the target's disks, applies `modules/hosts/smortress/disko.nix`,
generates `hardware.nix`, and delivers the pre-generated host key. Commit the
generated hardware config, then run `nix run .#bootstrap`.

- **Backup disk**: `/dev/disk/by-label/backup` (`backup.device`). Format and
  label a second disk once (`mkfs.ext4 -L backup /dev/sdX`). The module only
  mounts it, with `nofail`; the backup units declare `RequiresMountsFor` and
  fail loudly when it is absent.
- **Host key**: `/etc/ssh/ssh_host_ed25519_key` is the age recipient that
  decrypts the host's sops file. Losing it means restoring the key or re-keying
  (see Recovery in `README.md`).
- **Out-of-band access**: the physical console. There is no inbound SSH port;
  SSH is tunnel-only.

### smorespro

<!-- manual-step: host/smorespro -->

Intel laptop (NixOS). Install with the same `host-key`/`install` flow as
smortress, then enroll the fingerprint reader once after activation:

```sh
fprintd-enroll
fprintd-verify
fprintd-list "$USER"
```

Fingerprint auth is for the lock screen only; it is deliberately not enabled
for `sudo`/`su`.

Maki's personal profile on this host has no `NEURALWATT_API_KEY` or
`BRAVE_API_KEY`: those secrets live only in `secrets/smortress.yaml`. Use the
`work` AI profile or provision keys out of band.

### smoreswork

<!-- manual-step: host/smoreswork -->

The employer's macOS laptop (home-manager only; no NixOS configuration). Install
Nix, then:

```sh
nix run github:smores56/nix-config#bootstrap
```

`bootstrap` derives the configuration name from the machine's hostname and
user; on a laptop whose OS hostname is not `smoreswork`, override both:
`BOOTSTRAP_USER=sam BOOTSTRAP_HOST=smoreswork ...`.

MDM enrollment, FileVault, and OS updates stay with the employer; this repo only
manages the user environment.

## Secrets

All secrets live in `secrets/smortress.yaml`, which only smortress can decrypt.
Edit them with:

```sh
nix shell nixpkgs#sops -c sops secrets/smortress.yaml
```

After editing, commit and run `sudo nixos-rebuild switch` on smortress so
sops-nix redeploys `/run/secrets`. Never place a secret in the Nix store.

### cloudflare-api-token

<!-- manual-step: secret/cloudflare-api-token -->

One root-only token shared by OpenTofu and the email alert sender. Mint it at
<https://dash.cloudflare.com> → My Profile → API Tokens with:

- Zone:DNS:Edit for `sammohr.dev`;
- Access: Apps and Policies:Edit;
- Notifications:Edit;
- Email Sending:Edit.

Readers: `nix run .#cloudflare-*` and the `cloudflare-email` /
`backup-freshness` units. Rotate in the dashboard, update this key, rebuild, and
prove it with `sudo nix run .#cloudflare-plan`.

### cloudflared-credentials

<!-- manual-step: secret/cloudflared-credentials -->

The tunnel credentials JSON (`TunnelID`, `TunnelSecret`, `AccountTag`). The
`TunnelID` field is the authoritative tunnel UUID used by OpenTofu; no UUID is
authored in the repo and `webProxy.tunnelName` is only a label.

Create or reissue the tunnel under Zero Trust → Networks → Tunnels and paste the
JSON here. Changing the tunnel means rebuilding the host and re-running
`cloudflare-apply`.

### github-key-pat

<!-- manual-step: secret/github-key-pat -->

User-readable token used by `bootstrap` for `gh auth login --with-token`.
Classic token with `write:public_key` and `write:ssh_signing_key`, or a
fine-grained token with the account permissions "Git SSH keys: write" and "SSH
signing keys: write". Mint at GitHub → Settings → Developer settings → Personal
access tokens.

A lapsed token fails `bootstrap` hard; blank the secret and rebuild to fall back
to the device-code flow.

### github-repo-pat

<!-- manual-step: secret/github-repo-pat -->

Classic `repo`-scoped token, root-only, read by the GitHub mirror and metadata
units (`githubBackup.tokenFile`): ghorg, `python-github-backup`, and the
verifier (`gh`, via `GH_TOKEN` in its environment). ghorg embeds it in git's
argv, so it is visible in `/proc/<pid>/cmdline` during a run; the backup guide
records that accepted window. pgb receives it as a `file://` path, so it stays
out of argv. Fine-grained tokens cannot read wikis, so `--clone-wiki` would
silently omit them. Mint at GitHub → Settings → Developer settings → Personal
access tokens.

The mirror's probe repo (`sdlc`) must be refreshed on every run; a token
that is valid but has lost `repo` scope fails the run. The verifier also fails
when the token's repo listing no longer matches the mirror, so a scope loss is
caught the same night.

### proton-pass-pat

<!-- manual-step: secret/proton-pass-pat -->

`pass-cli` personal access token, user-readable, scoped read-only to the
Hosting and Identity vaults. Proton caps these at one year. Used by `bootstrap`,
`ssh-pub-keys`, and the `cloudflared-access` wrapper. Mint under Proton Pass →
Settings → Access tokens.

### calibre-password

<!-- manual-step: secret/calibre-password -->

OPDS password for the single `smores56` user, user-readable. The service
re-applies it on every start, so rotating is: edit this key, rebuild, restart
`calibre-server` (the rebuild restarts it) and refresh OPDS clients.

### neuralwatt-api-key

<!-- manual-step: secret/neuralwatt-api-key -->

Hosted-inference key, user-readable, exported by the fish init as
`NEURALWATT_API_KEY` for maki's provider config. Rotate in the Neuralwatt
console, update this key, rebuild, and open a new shell.

### brave-api-key

<!-- manual-step: secret/brave-api-key -->

Brave Search API key, user-readable, exported by the fish init for maki's
websearch plugin. Page Assist keeps its own copy in the browser. Rotate in the
Brave dashboard, update this key, rebuild, and open a new shell.

## Providers

Tofu providers come from `tofu/versions.tf`; notification policies come from
`tofu/main.tf`.

### cloudflare

<!-- manual-step: provider/cloudflare -->

The only OpenTofu provider. The zone `sammohr.dev` already lives in the account;
OpenTofu manages a wildcard proxied CNAME, the `ssh`/`llm`/`memory` Access
applications, the email allow-list and service-auth policies, and the
tunnel-health and service-token-expiry notifications.

Manual, one-time (dashboard):

- Create the tunnel and store its credentials (see
  `cloudflared-credentials`).
- Mint the Access service token(s) used by unattended clients; the service-auth
  policy references them. OpenTofu does not create tokens. One
  `any_valid_service_token` policy covers `ssh`, `llm`, and `memory`, so any
  service token in the account reaches all three endpoints.
- Onboard the Email Service sending subdomain (`send.sammohr.dev`) and add its
  SPF/DKIM/DMARC records. Verify the destination (`sam@sammohr.dev`). Leave the
  apex DMARC record alone (`p=reject`).
- Delete stale DNS records, Access applications, and policies left by the
  retired reconciler; it never deleted anything. Import any object you want to
  keep before the first apply.
- The personal-site Worker and the `keyboards.sammohr.dev` redirect are
  dashboard objects, not OpenTofu.

Every change: `sudo nix run .#cloudflare-plan`, review the plan, then
`sudo nix run .#cloudflare-apply`. State is root-only in
`/var/lib/cloudflare-tofu` and backed up as `CloudflareTofu`. `prevent_destroy`
guards the applications and policies; remove it deliberately if you mean to
delete them.

## Backup datasets

Datasets come from `backup.datasets` on every NixOS host. Each one is driven by
the shell driver [`backup.sh`](../modules/features/backup/backup.sh), packaged
as `backup`; a manual run passes the same flags the unit uses (`--name`,
`--source`, `--backup-root`, `--remote`, `--rclone-config`, `--offsite`,
`--exclude`, `--full-check`).

Each dataset runs `backup-<name>.service` on its timer and writes
`/var/backup/<Name>/BACKUP-LAST-SUCCESS` after a run that verified the mirror or
found nothing to verify. A run with a prior failure marker does not refresh it.
Inspect runs with:

```sh
systemctl list-timers 'backup-*'
systemctl status backup-photos.service
journalctl -u backup-photos.service -n 100
```

A failed run leaves `BACKUP-FAILED`. The freshness timer emails when
`BACKUP-LAST-SUCCESS` is older than the dataset's limit (default 26h; weekly
datasets get 8d). The operator guide — guarantees, trigger semantics, restore,
and prune procedures — is
[`modules/features/backup/README.md`](../modules/features/backup/README.md).
Run [`drills/restore-drill.sh`](../modules/features/backup/drills/restore-drill.sh)
when changing the driver.

### CloudflareTofu

<!-- manual-step: dataset/CloudflareTofu -->

OpenTofu state for the edge objects: `/var/lib/cloudflare-tofu`, daily 00:15.
Losing state is recoverable by importing the existing objects
(`sudo nix run .#cloudflare-tofu -- import <address> <id>`), not data loss.

### GitHub

<!-- manual-step: dataset/GitHub -->

Git bare mirrors plus issue/PR metadata under `/var/lib/github-mirrors`,
nightly 00:30, local and offsite (`proton:GitHub`). Seeded on 2026-10-19; later
runs transfer deltas only. The pre-unit refreshes every repo with ghorg, then
runs `python-github-backup` incrementally into `meta/`, and fails unless the
probe repo (`sdlc`) was refreshed. It also fails on a repo-set mismatch against
`gh api user/repos`, an issue/PR count drift beyond the documented slack, a
stale pgb `last_update`, or a failed `git fsck` sample; evidence is written to
`manifests/<date>/`.

A monthly full metadata pass (`github-metadata-full.timer`, first Sunday 09:00)
rebuilds `meta` without `-i` into `meta.new`, verifies it, and swaps it in under
the host lock. Check the last result with:

```sh
systemctl status github-metadata-full.service
jq . /var/lib/github-mirrors/manifests/$(date -u +%F)/counts.json
```

Restore a repository from `/var/backup/GitHub/current/smores56_backup/<repo>`
(or `proton:GitHub`). It is a bare mirror: clone from it directly, or push it
back with `git push --mirror`. Issues, PRs, discussions, releases, and
attachments are archived JSON under `.../current/meta/repositories/<repo>/`,
not restorable state: GitHub has no issue-import that preserves numbers and
cross-references, so recreating a lost issue is a manual copy from the JSON.
The mirror token is the classic `repo`-scoped `github-repo-pat` (root-only,
0400), shared by ghorg, pgb, and the verifier; it can write to every repo the
account reaches, but these units only read.

### MemoryExport

<!-- manual-step: dataset/MemoryExport -->

Copy of `/var/lib/memory/export` taken at 05:30 (the export itself runs nightly
from `memory-export.timer`, from midnight with up to an hour of delay), mirrored
locally to `/var/backup/MemoryExport/current` and offsite to
`proton:MemoryExport` like the other datasets. Each directory holds one registry
snapshot, the `episodes.jsonl` dump, the manifest, and a best-effort FalkorDB
RDB of the same timestamp. The export directory keeps seven snapshots and the
driver versions what it replaces, so the mirror grows until the versions are
pruned by hand. Restore with `just memory-restore <dir>` from
`/var/backup/MemoryExport/current`; when the graph snapshot is missing or older
than the registry, replay it with `just memory-reindex --all` afterwards.

### Music

<!-- manual-step: dataset/Music -->

`/var/lib/media/Music`, daily 05:00, offsite and change-triggered. Restore with
the drill, or:

```sh
sudo flock /run/lock/media-backup.lock \
  rclone copy proton:Music /restore/Music --config /var/lib/backup/rclone.conf
```

### Photos

<!-- manual-step: dataset/Photos -->

`/var/lib/media/Photos` (the Immich library), daily 03:00, full check Sundays
06:00, change-triggered. A generated pre-unit dumps PostgreSQL as `postgres`;
the driver copies it to `current/db/immich.dump` and fails the run if the
dump is missing or stale. `thumbs` and `encoded-video` are excluded because
Immich rebuilds them from the originals.

Restore both the database dump and the library; the procedure (including
`runuser -u postgres`) is in the backup README.

### Videos

<!-- manual-step: dataset/Videos -->

`/var/lib/media/Videos`, daily 01:00, full check Sundays 07:00, offsite and
change-triggered.

### LobeChat

<!-- manual-step: dataset/LobeChat -->

`/var/lib/lobechat`, daily 02:00, full check Sundays 10:00. The pre-unit dumps
PostgreSQL as `postgres`; the driver copies it to `current/db/lobechat.dump` and
fails the run if the dump is missing or stale. The source tree includes the
generated secrets under `secrets/`, so a restore keeps sessions and S3
credentials valid. Restore the dump into a scratch database with
`runuser -u postgres -- pg_restore --no-owner -d <db>` (the backup README shows
the full drill).

### RustFS

<!-- manual-step: dataset/RustFS -->

`/var/lib/rustfs` (the LobeChat S3 bucket), daily 04:00, full check Sundays
11:00, change-triggered. Restore by stopping `podman-rustfs` and copying
`current/` back, or by uploading the objects with `mc`. The bucket itself is
recreated by `lobechat-s3-bucket.service`; objects are not.

## Public services

Services come from `webProxy.services` on each NixOS host. Each becomes
`<name>.<domain>` through the tunnel. `ssh`, `llm`, `memory`, `chat`, and `s3`
have Cloudflare Access applications (hand-written in `tofu/`); `access.enable`
on any other service fails evaluation. Calibre and Immich are public and rely
on their own app auth.

### smortress/calibre

<!-- manual-step: service/smortress/calibre -->

`calibre.sammohr.dev` → loopback `ports.calibre`, HTTP, public (no Access).
OPDS clients authenticate as `smores56` with `calibre-password`.

### smortress/immich

<!-- manual-step: service/smortress/immich -->

`immich.sammohr.dev`, public (no Access) and protected by Immich's own login.
Phones also use the LAN URL
`http://<lan-ip>:2283` (`immich.lanSources`) because Cloudflare caps a single
upload at 100 MB and Immich neither chunks nor resumes. Configure both URLs in
the mobile app.

### smortress/llm

<!-- manual-step: service/smortress/llm -->

`llm.sammohr.dev`, TCP to llama.cpp, with the service-auth policy so maki can
call it unattended. `api_key = "none"`; the tunnel and Access are the boundary.

### smortress/memory

<!-- manual-step: service/smortress/memory -->

`memory.sammohr.dev` → the loopback memory wrapper (`ports.memoryMcp`), TCP to
the server's loopback, with the same service-auth policy. The wrapper derives
nothing itself: it validates the group header the Maki shim sends, refuses work
groups, enforces a 60s deadline per tool call, and is the only tunnel target.
MCP tool calls are authenticated by Access alone. Raw Graphiti runs on an
internal loopback port in `modules/nixos/memory.nix` and is never tunneled. The
wrapper owns the typed registry, verifies queued writes against FalkorDB, and
exposes `/internal/episodes` and `/internal/lookup` for `memory ingest`.

Those two ingest routes carry a second gate. The tunnel is a raw TCP forward,
so the wrapper sees `127.0.0.1` as the peer for every tunneled request and the
loopback check can never tell a tunneled client from a local one. At startup
the wrapper mints a random token into `/var/lib/memory/internal.token`
(mode 0640, owned by the `memory` service group) and requires
`Authorization: Bearer <token>` on both routes; the loopback check stays as
defence in depth. `memory ingest` reads the same file, so the human user must
be in the `memory` group — `modules/nixos/memory.nix` adds
`users.users.<machine.username>.extraGroups` when `memory.enable` is set, and
the membership only applies after `just switch smortress` **and** a fresh login
session (or `newgrp memory`). `MEMORY_INTERNAL_TOKEN_FILE` overrides the path,
which matters only for a deliberate run from another host: the token is
regenerated on every wrapper start, so a copied file goes stale.
`/internal/lookup` takes at most 10,000 hashes and both routes reject bodies
over 1 MB.

Graphiti extracts through `memory-llm-proxy` on `127.0.0.1:8082`, which is
Memory's single egress point to Neuralwatt (`api.neuralwatt.com`). The gateway
holds the account key — read from the `neuralwatt-api-key` sops secret through a
systemd credential, never from the environment or the Nix store — injects
`Authorization: Bearer …` to the upstream request (Graphiti's required
`api_key: "none"` placeholder is replaced; a real client-supplied token is
forwarded untouched), and adds
`reasoning_effort: "none"` to chat completions. A reasoning model otherwise
spends its whole token budget thinking and returns empty content, which
Graphiti drops. Graphiti itself runs with `api_key: "none"`.

Episode text goes to Neuralwatt by design; the work-group refusal runs before
any write, so employer content never reaches it. Rotating the key is: update the
sops secret and rebuild — `sops.secrets.neuralwatt-api-key` restarts
the gateway, which reads the credential once at start. A **missing** credential
makes `LoadCredential` fail, so the gateway never starts and the wrapper's
`preStart` (which waits on the gateway) fails with it: reads stop too. An
**empty** credential lets the unit start; every proxied request then returns
503 `configuration_error` while `/health` still answers. A real client-supplied
token is forwarded untouched only when the gateway has a key — without one the
503 is returned before headers are inspected.

The listener is loopback-only and never tunneled, but it is **unauthenticated by
design**: any local process that can reach `127.0.0.1:8082` can spend the
Neuralwatt account through it. Treat the host's user boundary as the billing
boundary. Its `/health` only proves the gateway process is alive; check upstream
access through the proxied `/v1/models`. Request bodies over 10 MB are rejected,
and an upstream read stall is a 504.

The tier math is three concurrent upstream slots: two for memory
(`MEMORY_UPSTREAM_CONCURRENCY=2`, mirrored by Graphiti's
`SEMAPHORE_LIMIT=2`) and one left for Maki's own chat on the same key. The
gateway's permit is held for the whole upstream request, streamed body
included, so it — not Graphiti's semaphore — is the real ceiling, and
oversubscribing only trades throughput for 429s: four in-flight episodes once
earned 944 429s out of 2,270 requests in 20 minutes while a 1,382-episode
backfill starved. A 429 or 503 is a rejection (the request never ran), so the
gateway retries those two — `MEMORY_UPSTREAM_RETRIES=6` attempts, honouring
`Retry-After` (seconds or HTTP-date, capped at 60 s) and otherwise backing off
exponentially with jitter — and returns the upstream 429/503 unchanged once
attempts run out. Nothing else is retried, and nothing is retried after a
response body has started. Because a queue that large drains over hours, the
wrapper's `MEMORY_RECONCILE_GRACE` is 12 hours: a shorter grace marked
still-queued writes failed and resubmitted them as duplicates. If 429s appear
again, lower `MEMORY_UPSTREAM_CONCURRENCY` (and `SEMAPHORE_LIMIT` with it)
before anything else.

A gateway outage is not a submission error. Graphiti answers `add_memory` with
200 and extracts from an in-memory queue, so a dead gateway leaves a `pending`
row with no episode in the graph (`Failed to process episode … Connection
error` in `journalctl -u memory-graphiti-mcp`) and the wrapper never prints its
"submission was deferred" line; the registry row is the only copy. The grace
above bounds when the reconciler replays it, so a drill needs a runtime
override — `MEMORY_RECONCILE_GRACE=300` in
`/run/systemd/system/memory-mcp.service.d/`, `daemon-reload`, restart — then the
first pass past the grace resubmits the content and the row goes `active` once
the episode is verified. Drilled 2026-10-23 with the gateway stopped: the write
stayed `pending` with zero graph episodes, replayed into exactly one episode
~20 s after the override restart, was searchable, and a repeat write of the same
content reported the existing uuid instead of queueing a second extraction.

Embeddings stay local by default: bge-m3 on `llama-cpp-embed` (`127.0.0.1:8183`,
1024 dimensions). `memory.embedder = "neuralwatt"` sends them through the same
gateway to `qwen3-embedding-8b` (4096 dimensions); the model is preview-only and
this account currently gets a 404, so the local service stays deployed either
way and flipping the switch means re-embedding the corpus at a new width.
`qwen3-embedding-8b` prefers an `Instruct: …` / `Query:` prefix on queries;
graphiti-core's OpenAI embedder sends the same text for queries and passages, so
expect a small retrieval penalty.

Personal machines run `cloudflared-memory`, which forwards loopback
`ports.memoryMcp` and injects the Access service token. Maki's generated
`~/.config/maki/mcp.toml` starts `memory-mcp-shim` (server `graphiti`) with
`MEMORY_MCP_URL` and the work markers from `config.user.work` in its
environment; the shim derives the project group from Maki's cwd and forwards to
the wrapper. The same package installs the `memory` CLI, and the personal
profile exports `MEMORY_PERSONAL_OWNER` from `config.user.githubUser` for its
ingest defaults.

Maki reads `mcp.toml` once at startup, and the shim derives the group once when
Maki starts it. Restart Maki after changing `mcp.toml` and after moving to a
different repository: `/cd` does not restart stdio children, so the group stays
fixed until Maki restarts.

The wrapper's typed registry (`registry.sqlite`, including the audit table)
lives in `/var/lib/memory`, owned by the `memory` system user (the FalkorDB
subdirectory stays root-owned). The database carries a `PRAGMA user_version`
schema version. A database one version behind is migrated in place on open
(`ALTER`/backfill statements in one transaction); an unversioned one, or one
newer than the code, is refused rather than guessed at. Restoring an export
taken before a schema bump is therefore fine: it is installed as-is and
migrated the next time the wrapper starts.

`created_at` is when the memory was written; `queued_at` is when it last
entered the pending queue (a replay sets it again, a repeat write keeps the
original `created_at`). The reconciler's grace window, the stale-write window,
the presence bound and `pending()` order read `queued_at`, so a replay starts
with a fresh grace instead of inheriting a months-old one.

**Backup.** The registry is the system of record, so its snapshot *is* the
memory backup: it holds every episode's normalized content and typed
provenance. The graph is a derived index: it is rebuilt only by re-ingesting
the corpus into a wiped store (`just memory-rebuild`).
`memory-export.timer` runs `memory-export.service` daily (00:00 plus up to an
hour of randomized delay, `Persistent=true`, as root because the FalkorDB data
directory is root-owned) and writes one timestamped directory under
`/var/lib/memory/export` (mode 0700, root):

- `registry.sqlite` — a consistent copy taken with SQLite's online backup API,
  so the wrapper keeps writing under WAL while it is copied;
- `episodes.jsonl` — every episode with typed provenance (group, uuid,
  content_hash, kind, origin, origin_ref, actor, cwd, tags, valid_at,
  created_at, queued_at, status, graphiti_uuid, promotion and tombstone
  fields) *and* its
  content, so memory is readable even without SQLite;
- `manifest.json` — creation time, `PRAGMA user_version`, per-status counts, and
  the sha256 of each file;
- `graph-<timestamp>.rdb` — the FalkorDB snapshot, when `BGSAVE` finished in
  time. The exporter issues one `BGSAVE` per run and polls `INFO persistence`,
  accepting `dump.rdb` only once the server's `rdb_last_save_time` has advanced
  past the value it read before the save; it never touches the AOF. A missing
  or failed graph snapshot is recorded in the manifest (`graph: null` plus
  `graph_error`) and the registry export still stands, but the command exits
  non-zero so the failed timer run is visible (and alerts, when
  `alerting.enable` is on).

Seven directories are kept; retention only deletes names that are export
timestamps *and* whose `manifest.json` reads, so a partial export (a crashed or
still-running run) is left for the operator rather than counted as one of the
kept snapshots, and the directory a run just wrote is never a prune candidate.
Inspect a run with `journalctl -u memory-export.service`. Take one immediately
with `just memory-export`. An export refuses to run while a restore holds the
lock described below.

**Restore drill.** `sudo memory restore <export-dir>` verifies every manifest
checksum *first*, refuses a registry schema other than the installed code's
(a newer one this code cannot read; an older one the wrapper will not open),
then stops `memory-mcp`, `memory-graphiti-mcp`, `memory-llm-proxy`, and
`memory-falkordb`. The graph store stops too: a running FalkorDB rewrites its
AOF, which would resurrect the data the restore is replacing. The live
`registry.sqlite` and its `-wal`/`-shm` are copied to
`registry.sqlite.pre-restore-<timestamp>`, the export's registry is installed
with one atomic rename, and only then are the replaced database's sidecars
dropped. Ownership (`memory:memory`) is settled on the staged copy *before* the
rename, so a failed `chown` leaves the previous registry in place, exits
non-zero, and names the parked copy. Delete the `*.pre-restore-*` registry files
once the restore checks out.

The graph is handled after the registry:

- the matching `graph-<timestamp>.rdb` is restored only when its timestamp
  equals the registry snapshot's. FalkorDB runs with `appendonly yes` and Redis
  loads the AOF in preference to the RDB, so the restore renames the existing
  `appendonlydir` to `appendonlydir.pre-restore-<timestamp>` — the old AOF is
  kept, never deleted, and otherwise the restored snapshot would be silently
  ignored. It then restarts `memory-falkordb`, because the RDB is only read at
  startup, and reports `graph: restored` only after that restart. Delete the
  parked `appendonlydir.pre-restore-*` once `GRAPH.LIST` and a search confirm
  the graph is the restored one;
- otherwise it refuses the graph, restores the registry alone, and tells you to
  restore an export whose graph snapshot matches, or to rebuild **both** stores.
  A restored registry does not rebuild with `memory-ingest`: it skips rows that
  already succeeded, so re-ingesting an `active` corpus into an empty graph
  extracts nothing. `just memory-reindex --all` is the replay path
  (`memory reindex`): it reads every episode content for a group in one query,
  requeues the active rows with no matching episode, and resubmits that slice
  immediately, so extraction starts now rather than after the reconcile grace.
  It is operator-only, defaults to the caller's group (`--all` for every group),
  handles a bounded slice per call and is safe to repeat — a row is only
  requeued when its episode is absent, and requeueing restarts its queue clock
  so the reconciler waits the grace window for the extraction instead of
  retrying it into `failed`. A group that looks almost entirely missing while
  its graph is not empty is refused unless `--force` is passed, because that
  usually means a wrong graph or a registry from another host. `just memory-rebuild` wipes the FalkorDB data *and* the
  registry, and only then does `just memory-ingest` rebuild anything
  (re-extraction of `active` rows is tracked in #219).

`--dry-run` verifies and prints the plan without stopping or writing anything;
`--no-stop` is accepted only together with `--dry-run`, because a real restore
always stops the services (swapping files under a running store is how a restore
corrupts itself); `--start` also starts `memory-llm-proxy`,
`memory-graphiti-mcp`, and `memory-mcp` after the graph restart; `--owner
user:group` sets the restored registry's owner (default `memory:memory`, an
empty value skips it). A restore writes `<state>/.restore-in-progress` for its
duration, and `memory export` refuses to run while it exists; a failed restore
leaves it in place, so remove it once the state is reconciled. The subcommand is
`memory restore` next to `memory export` — not `memory export restore` — and the
CLI is in the system profile on any host with `memory.enable`, so sudo finds it.
`just memory-restore <dir>` wraps it.

The drill the check suite runs (`tests/memory_export_restore.sh`) is the same
procedure against temp directories: a live WAL registry exports consistently, a
tampered file and a newer schema are refused, retention prunes only its own
complete directories, a mismatched graph snapshot is rejected in favour of the
rebuild path, the stop set reaches `memory-falkordb` and the graph restore
restarts it, a failed ownership step leaves the previous registry in place, and
an export refuses to run while the restore lock exists. It needs no root, no
FalkorDB, and no network.

**Offsite.** `backup.datasets.MemoryExport` mirrors `/var/lib/memory/export`
(the plain-tree, versioned driver) to the backup disk and Proton, so the
registry and its graph snapshot survive losing smortress. Recovery order is:
restore the export, then `memory reindex --all` when the graph snapshot is
missing or older, then confirm with a search.

**Evaluation.** `just memory-eval` runs `modules/features/ai/memory/eval/` against
the live store: 50 labelled queries (semantic, entity, temporal, exact) scored by
recall@5 and MRR for the graph-backed `memory search` against an FTS5/bm25 index
over the same registry rows, then 50 adversarial boundary queries that must
return no entry from a foreign project group. First measured run (2026-10-23,
1,385 episodes): recall@5 0.52 / MRR 0.40 against 0.86 / 0.60 for FTS5, mean
search latency ~4.5 s against ~0.5 ms, and zero foreign-group hits. That run
exposed a structural miss: the wrapper listed every node before any fact, so
while the node list was full no fact could reach the top five. The block now
alternates the two ranked lists; the same 50 queries on the drained corpus
(1,357 rows) measure recall@5 0.66 / MRR 0.42 against 0.78 / 0.55 for FTS5 at
mean 4.1 s against 0.7 ms — 40 of 50 answered somewhere in the block, 33 within
the top five, still zero foreign-group hits. Read both comparisons with care:
the baseline ranks whole episodes while the graph ranks extracted facts and
entities against gold strings that are verbatim corpus text, and a gold token
that merely appears inside an extracted fact sentence counts as a hit for it, so
fact-heavy positions score generously. Community summaries stay off
for now: the misses are single-fact lookups, not the multi-hop thematic questions
summaries help with, and building them costs an extra pass over the corpus.

Search cost on smortress over loopback (same 50 queries): p50 5.2 s, p95 7.9 s,
max 13.1 s, against ~1 ms for FTS5; a returned block is about 1.2–1.4k tokens,
inside the 2k budget the design targets. A Maki client adds tunnel latency on
top of that.



Activate after changing the wrapper, shim, package, LLM proxy, or export
unit:

```sh
just switch smortress
just home-switch smores <personal-host>
```

Verify on smortress:

```sh
systemctl status memory-mcp
curl 127.0.0.1:8182/health
systemctl status memory-llm-proxy
curl 127.0.0.1:8082/v1/models   # proxied to Neuralwatt (needs the credential)
curl 127.0.0.1:8082/health
cd ~/code/<repo> && memory status   # group, registry counts, graph/model readiness
systemctl list-timers 'memory-export*' && journalctl -u memory-export -n 20
```

**Corpus ingest.** The graph already holds episodes from earlier runs, but the
registry starts empty: the first ingest after this deploy sees an **empty
registry against a populated graph** and re-extracts the whole corpus,
duplicating episodes the graph already holds. That is expected and bounded
(one hosted extraction call per episode; the new rows become `active` when
their extraction lands). Reconciling the two stores means wiping both of them
(`just memory-rebuild`) and re-ingesting; making `memory-ingest` re-extract
already-`active` rows is tracked in #219. Deploy the gateway before ingesting: until
`just switch smortress` runs, Graphiti still extracts through the old route and
drops episodes. Then, on smortress:

```sh
systemctl status memory-llm-proxy
curl 127.0.0.1:8082/v1/models        # Neuralwatt answers through the gateway
redis-cli -p 6379 GRAPH.LIST         # group graphs (read-only peek)
memory ingest all --dry-run          # plan only; writes nothing
memory ingest all --limit 5 --dry-run
memory ingest all --limit 5          # small live sample, then the full run
```

`memory ingest all` (or `just memory-ingest` for the full corpus) reads the sdlc
issue list through `gh`, the markdown files under `~/Documents` (recursively),
and the personal clones in `~/code/github.com/<owner>` plus remote READMEs. Run
it on smortress, where the corpus lives and the wrapper's loopback is reachable;
it never talks to Graphiti or FalkorDB directly. Every source runs independently
under `all`; a source that cannot be read is reported in `source_errors` and in
`failures` (with `source_id: "*"`) instead of aborting the others.

Each run writes `~/.local/state/memory/ingest-<timestamp>.json` (build/lookup/
submit counts, failures, and timings) and nothing else: the report is never read
back. To resume, run the same command again. The client asks the wrapper's
`/internal/lookup` which content hashes already exist:

- `active` and `pending` rows are skipped. A source that moved to another group
  looks missing there and is submitted to the new group.
- `failed` rows are resubmitted, which resets their attempts. Tombstoned rows are
  left alone until the content is deliberately written again, and the
  reconciler invalidates any graph episode their extraction produced after the
  tombstone.
- Missing episodes are submitted through `/internal/episodes` with explicit
  `kind` and `valid_at`; the wrapper records them as pending and its reconciler
  resolves them. A retry is bounded and never overlaps an in-flight submission.

**Maki sessions.** `memory ingest sessions` (and `memory ingest all`, which
includes the session sample by default) reads Maki's JSONL transcripts from
`$MAKI_SESSIONS_DIR`, else `$XDG_STATE_HOME/maki/sessions`, else
`~/.local/share/maki/sessions` and `~/.maki/sessions`, and passes
`--sessions-dir`/`--session-limit` to override either. The sample is the 50 most
recently modified session files; each one is bounded to the first and last
messages within a 24k-character transcript, so a 74 MB session cannot exhaust
the token budget. Each session is summarized by `deepseek-v4.1-flash`
(`MEMORY_SUMMARY_MODEL` overrides) at temperature 0 with a JSON-object response
asking for a prose summary plus explicit decisions, constraints, errors, and
user preferences; every one of those becomes its own episode, so all of a
session's episodes share `origin=session` and `origin_ref=<session id>`.
Session text is personal and leaves this machine for summarization through the
loopback gateway; only the summary and the extracted items are stored, and a
session whose cwd is a work checkout is refused before any request is made. A
session whose cwd does not exist here is refused too, because its work markers
cannot be checked: a cross-machine session must be ingested where its cwd
exists. Only the cwd's path components are checked for employer markers; text
inside a personal checkout is not scanned for employer content.

An unchanged session is not re-summarized. A disposable cache at
`$MEMORY_SESSIONS_CACHE` (default `~/.local/state/memory/sessions.json`) is
keyed by session id plus the bounded transcript's SHA-256, so a repeated run
reuses the earlier summary and cannot paraphrase the same session into a second
episode; a changed transcript is summarized again. The cache is not a ledger:
the registry still decides duplicates, and the file can be deleted at any time.
`--limit` bounds episodes per source but not sessions; `--session-limit` bounds
the sample, so `memory ingest all` spends about that many summary calls.

The summary call runs from the operator's shell, not from a unit, so it reaches
the gateway at `MEMORY_LLM_URL` (default `http://127.0.0.1:8082`) and needs no
Neuralwatt key. Per-session wall time, prompt/completion `usage` tokens, and an
estimated cost live under `sessions` in the run report; the prices are
`MEMORY_SUMMARY_PRICE_IN`/`MEMORY_SUMMARY_PRICE_OUT` (USD per million, default
0.15/0.60), and the summary line is printed on stderr. A missing `usage` block
reports `cost unknown` rather than $0, and retries accumulate tokens because
every paid attempt counts. `--session-concurrency`
(default 3) bounds simultaneous summary calls, and `--dry-run` parses and
estimates tokens without calling the model; a live run prints the sampled count
and its token/cost estimate to stderr before the first call.

Extraction is one hosted chat call per episode, so a full corpus takes hours.
`--concurrency` (default 4) bounds simultaneous submissions; the wrapper's
reconciler verifies them in the background. For a long run, start it in a
transient user unit:

```sh
systemd-run --user --unit memory-ingest --collect --setenv=MEMORY_MCP_URL=http://127.0.0.1:8182/mcp \
  -- memory ingest all
systemctl --user status memory-ingest
journalctl --user -u memory-ingest -f
```

The tunnel ingress and Access application are unchanged by this step. For a
first deployment, apply the Memory Access application **before** rebuilding
smortress:

```sh
sudo nix run .#cloudflare-apply
just switch smortress
```

The wildcard CNAME already exists, so the rebuild adds the ingress; applying
tofu first means Access is in place the moment the hostname starts routing.
The email policy is inert for this TCP endpoint (service tokens only).

### Rebuilding the store

The registry is authoritative and the graph is derived, so a rebuild is: stop
the memory services, delete the graph data and the registry, start them again,
and re-ingest. It is the only destructive memory operation, and it also changes
the vector width when `memory.embedder` changes.

```sh
just switch smortress     # applies the embedder choice (qwen3, 4096-d)
just memory-rebuild       # stop, wipe, start (sudo)
just memory-ingest        # re-extract the corpus; hours, run in a user unit
```

`just memory-rebuild` removes `/var/lib/memory/falkordb/*`, `registry.sqlite*`,
`index.sqlite*`, `audit.jsonl` and the internal token (regenerated at start).
The first `memory ingest all` then treats every planned hash as missing and
re-embeds the corpus at the new width. Do not run it while anything else is
writing memory. Since #223 there is an export to fall back on: take one with
`just memory-export` (or restore the newest with `just memory-restore <dir>`)
before wiping, because a rebuild that goes wrong otherwise loses the registry,
which is the system of record.

### smortress/chat

<!-- manual-step: service/smortress/chat -->

`chat.sammohr.dev` → the loopback LobeChat container (`ports.lobechat`), HTTP
behind Access. LobeChat is the phone PWA; its own email/password login is the
second layer. `AUTH_ALLOWED_EMAILS` admits only `config.user.email`, so no other
account can be created.

First start generates `/var/lib/lobechat/secrets` (root-owned) and copies the
DB password to `/run/lobechat/db-password` (readable by `postgres`). It runs
the full schema migration before answering; `lobechat-wait` gives it 600s. The
image is pinned by digest, and `FTS_SEARCH_PROVIDER=pg_like` is required because
the host Postgres has no ParadeDB `pg_search`.

Knowledge-base embeddings follow `memory.embedder` through LobeChat's
OpenAI-compatible `newapi` slot: qwen3-embedding-8b through the loopback memory
gateway (`ports.memoryLlmProxy`), or bge-m3 on `ports.memoryEmbed`. Either way
the response is 1024-d, because LobeChat sends `dimensions: 1024` on every call
and its pgvector column is fixed at that width. Switching the embedder keeps
the schema but requires re-indexing the knowledge base: vectors from different
models are not comparable. Chat uses Neuralwatt `deepseek-v4.1-flash`; local
`qwen3.8-27b` (the `vllm` slot) is the fallback. Brave search is enabled with
the existing `brave-api-key`.

The model lists spell abilities explicitly (`<context:fc:vision>`). An
env-listed model without `fc` is treated as unable to call tools, which hides
agent mode, web search, and MCP entirely; that is the only place LobeChat
learns those abilities for a custom model.

**Graphiti MCP.** Add the server in the UI (Settings → Connectors → Add
Custom Connector → Advanced → Headers); there is no env var for MCP servers.

- URL: `http://127.0.0.1:8182/mcp`, transport `http` (streamable HTTP).
- Headers: `X-Memory-Group: global`, `X-Memory-Cwd: /phone`,
  `X-Memory-Actor: lobechat`.

The wrapper refuses a tool call without `X-Memory-Group` and an absolute
`X-Memory-Cwd`; both are client headers, never model output. `global` is the
shared personal group, so phone writes are searchable from every project. The
write records `actor=lobechat` and `cwd=/phone` as provenance; the pinned
wrapper has no source/source-id header, so that pair is the phone marker. The
wrapper has no auth of its own; loopback and the Access boundary are the
controls.

For the first deployment, apply the new Access applications before rebuilding:
`sudo nix run .#cloudflare-apply`, then `just switch smortress`. The wildcard
CNAME already exists, so the rebuild only adds the ingress.

It refuses work groups and records the source/source-id in every episode's
provenance. LobeChat's built-in Memory has no deployment-wide off
switch: after the first login open Settings → Memory and disable it, so Graphiti
is the only memory system.

### smortress/s3

<!-- manual-step: service/smortress/s3 -->

`s3.sammohr.dev` → the loopback RustFS container (`ports.rustfs`) behind
Access. LobeChat signs presigned URLs with this public endpoint and uses
`http://127.0.0.1:9000` for server-side reads and writes. Browser uploads are
presigned PUTs to the public endpoint, so they still need the `s3` Access
session; only server-side work avoids it. The bucket (`lobe`) is created by
`lobechat-s3-bucket.service`; RustFS root credentials are generated on first
start and shared with LobeChat through `/run/lobechat`. RustFS is configured to
allow CORS from `https://chat.<domain>`, and the Access app bypasses `OPTIONS`
preflights so the browser can reach it.

Access puts an interactive login in front of the presigned URL host. The
cookie is host-scoped, so a `chat` session does not cover `s3`: on the S24,
complete the Access login once on `s3.sammohr.dev` before uploading or
downloading files. If that remains unreliable, the fallback in #227 is one
Access application covering both hostnames or proxying downloads.

### smortress/ssh

<!-- manual-step: service/smortress/ssh -->

`ssh.sammohr.dev`, SSH to the loopback sshd (key-only), with service auth for
`cloudflared access ssh`. `ssh` must keep Access enabled; evaluation fails
otherwise.

## Flake apps

Apps come from `modules/flake/apps.nix`. Run them as `nix run .#<name>`; from
another machine use `github:smores56/nix-config#<name>`.

### bootstrap

<!-- manual-step: app/bootstrap -->

Fresh machine (requires only Nix): clones the repo via ghq, switches
home-manager, fetches SSH public keys from Proton Pass, logs in GitHub, and on
NixOS applies the system configuration. `bootstrap.sammohr.dev` is not
provisioned by this repo; use the flake app.

### install

<!-- manual-step: app/install -->

`nix run .#install -- <host> root@<ip>`. Runs nixos-anywhere and the host's
disko layout (wiping disks), generates and writes the host's `hardware.nix`, and
delivers `secrets/hosts/<host>/` when present.

### host-key

<!-- manual-step: app/host-key -->

Generates the pre-generated host SSH key under the gitignored
`secrets/hosts/<host>/` and prints its age recipient. Add that recipient to
`.sops.yaml` as a key and as a `secrets/<host>.yaml` creation rule, then
`sops updatekeys secrets/<host>.yaml`.

### cloudflare-plan

<!-- manual-step: app/cloudflare-plan -->

`sudo nix run .#cloudflare-plan` runs a read-only plan from the root-only state
directory. Run it after any change to `tofu/` and after rotating the token.

### cloudflare-apply

<!-- manual-step: app/cloudflare-apply -->

`sudo nix run .#cloudflare-apply` applies the reviewed plan. Never apply on a
fresh state directory before importing existing objects; `prevent_destroy`
protects the applications and policies, but a wrong plan can still create
duplicates.

### cloudflare-tofu

<!-- manual-step: app/cloudflare-tofu -->

`sudo nix run .#cloudflare-tofu -- <args>` runs raw `tofu` in the state
directory, for `import`, `state list`, `state rm`, and recovery.

## Alert paths

Alert paths come from `tofu/main.tf` (notification policies) and from the
`alerting` module (`backup-freshness`, `cloudflare-email@`). All of them email
`sam@sammohr.dev` through Cloudflare Email Service; no listener runs on the
host. A Cloudflare outage silences email and the tunnel together — the console
is the fallback.

### backup-freshness

<!-- manual-step: alert/backup-freshness -->

`backup-freshness.timer` runs every five minutes and emails once per stale
period. Test it without waiting for a real lapse:

```sh
sudo touch -d '2 days ago' /var/backup/Music/BACKUP-LAST-SUCCESS
sudo systemctl start backup-freshness
sudo systemctl start backup-music   # refresh the marker
```

Delete `/run/backup-freshness/Music.alerted` to reset the once-only flag.

### unit-failure

<!-- manual-step: alert/unit-failure -->

Every backup unit's `OnFailure` starts `cloudflare-email@%n.service`, which
emails the unit's status and last 50 journal lines. Test the path without
breaking a backup:

```sh
sudo systemctl start cloudflare-email@backup-github.service
```

That sends one email about the (successful) unit; a real failure sends one per
failed run. The template reads the token from
`/run/secrets/cloudflare-api-token`.

### tunnel-health

<!-- manual-step: alert/tunnel-health -->

OpenTofu `cloudflare_notification_policy.tunnel_health` alerts on health events
for the configured tunnel. It is provider-side, so there is no local test;
confirm the policy in the dashboard after `cloudflare-apply`.

### service-token-expiry

<!-- manual-step: alert/service-token-expiry -->

OpenTofu `cloudflare_notification_policy.service_token_expiry` warns before an
Access service token expires. Renew the token in the dashboard, update the
clients that embed it (Proton Pass), and re-run `cloudflare-plan`.
