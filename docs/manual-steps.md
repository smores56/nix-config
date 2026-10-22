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
groups, enforces a 60s deadline per tool call, dedupes writes, and is the only
tunnel target. The wrapper has no authentication of its own; Access is the only
route. Raw Graphiti runs on an internal loopback port in
`modules/nixos/memory.nix` and is never tunneled.

Graphiti reaches the chat model through `memory-llm-proxy` on
`127.0.0.1:8082`, which adds `reasoning_effort: "none"` to OpenAI chat
completions. llama.cpp defaults to thinking and graphiti-core sends no
per-request control, so extraction would generate reasoning until the token
budget ran out and return empty content, which Graphiti drops. The proxy is
loopback-only and never tunneled; its port lives in `modules/nixos/memory.nix`
because no other module reads it. Maki keeps using `ports.llm` (8081) directly;
do not point it at 8082, and do not give the proxy a thinking mode. The proxy's
`/health` only proves the proxy process is alive (Graphiti's readiness probes
it); check the chat model through the proxied `/v1/models`. Request bodies over
10 MB are rejected and an upstream read stall is a 504.

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

The wrapper's SQLite index and audit log live in `/var/lib/memory`, owned by the
`memory` system user (the FalkorDB subdirectory stays root-owned). That path is
**not backed up** yet: there is no export or snapshot task for the graph volume
or the index/audit, so losing the host loses both.

Activate after changing the wrapper, shim, package, or LLM proxy:

```sh
just switch smortress
just home-switch smores <personal-host>
```

Verify on smortress:

```sh
systemctl status memory-mcp
curl 127.0.0.1:8182/health
systemctl status memory-llm-proxy
curl 127.0.0.1:8082/v1/models   # proxied through to the chat model
curl 127.0.0.1:8082/health
cd ~/code/<repo> && memory status   # group, index counts, graph/model readiness
```

**Corpus ingest.** Deploy the LLM proxy before ingesting: until
`just switch smortress` runs, Graphiti still extracts through the thinking
model and drops episodes. Then, on smortress:

```sh
systemctl status memory-llm-proxy
curl 127.0.0.1:8082/v1/models        # the chat model answers through the proxy
redis-cli -p 6379 GRAPH.LIST         # group graphs (read-only peek)
memory ingest all --dry-run          # plan only; writes nothing
memory ingest all --limit 5 --dry-run
memory ingest all --limit 5          # small live sample, then the full run
```

`memory ingest all` (or `just memory-ingest` for the full corpus) reads the sdlc
issue list through `gh`, the markdown files under `~/Documents` (recursively),
and the personal clones in `~/code/github.com/<owner>` plus remote READMEs. It
must run on smortress: the raw Graphiti port (`127.0.0.1:8184`) and FalkorDB
(`127.0.0.1:6379`) are loopback-only, and verification, reconcile, and repair
read them. Every source runs independently under `all`; a source that cannot be
read is reported in `sources.<name>.error` and in `failures` (with
`source_id: "*"`) instead of aborting the others.

Each run writes `~/.local/state/memory/ingest-<timestamp>.json` (counts per
source and group, duplicates, adopted/superseded/reconciled/repairs, failures,
and which presence backend was used) and updates
`~/.local/state/memory/ingest-state.json`. To resume, run the same command
again:

- Verified `(group, source, source_id)` entries are skipped. A source that
  moved to another group (a task inheriting a different `repo:` label) writes
  to the new group, and changed content supersedes the old index row (the old
  graph episode remains by design).
- Episodes a previous run attempted but the graph never received are
  tombstoned in the wrapper index and rewritten, so the write is a queue rather
  than a duplicate. On a first run there is nothing to reconcile, so no
  tombstone or "no stored episode" audit row is produced.
- Episodes that are still absent after the 600s grace are recorded as failed
  and **not** rewritten: Graphiti extracts asynchronously, so a late in-flight
  episode would otherwise be duplicated, and the wrapper has no graph-level
  delete. Inspect `failures`, then either re-run (reconcile handles the row) or
  pass `--repair`, which rewrites a previously attempted entry once, and only
  after FalkorDB proves the exact `id=`/`hash=`/`source`+`source_id` is absent.
  When FalkorDB is unreachable the run falls back to `get_episodes` (the report
  says `presence: get_episodes`) and repairs are refused.
- `--force --reset-state` archives the state file (`ingest-state.json.bak-*`)
  and treats the run as a first run; both flags are required because a reset
  re-attempts every planned episode. The state file is `flock`ed, so a second
  ingest exits instead of interleaving writes.

Extraction is one 27B chat call per episode, so a full corpus takes hours. The
default is `--batch 1` with a 600s per-episode grace; keeping one write in
flight is what stops Graphiti's in-memory queue from dropping work. For a long
run, start it in a transient user unit:

```sh
systemd-run --user --unit memory-ingest --collect --setenv=MEMORY_MCP_URL=http://127.0.0.1:8182/mcp \
  --setenv=MEMORY_GRAPHITI_URL=http://127.0.0.1:8184/mcp -- memory ingest all
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

Knowledge-base embeddings use the shared bge-m3 server at
`ports.memoryEmbed` through LobeChat's OpenAI-compatible `newapi` slot. Chat
uses Neuralwatt `deepseek-v4.1-flash`; local `qwen3.8-27b` (the `vllm` slot) is
the fallback. Brave search is enabled with the existing `brave-api-key`.

**Graphiti MCP.** Add the server in the UI (Settings → Connectors → Add
Custom Connector → Advanced → Headers); there is no env var for MCP servers.

- URL: `http://127.0.0.1:8182/mcp`, transport `http` (streamable HTTP).
- Headers: `X-Memory-Group: global`, `X-Memory-Cwd: /phone`,
  `X-Memory-Actor: lobechat`, `X-Memory-Source: lobechat`,
  `X-Memory-Source-Id: phone`.

The wrapper has no auth of its own; loopback and the Access boundary are the
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
