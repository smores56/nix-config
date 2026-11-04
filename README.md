# nix-config

Personal Nix configuration for macOS and NixOS machines, managed with
[flakes](https://nixos.wiki/wiki/Flakes) and
[home-manager](https://github.com/nix-community/home-manager).

## Structure

Modules are composed by **profiles**, not auto-imported. Each
`modules/hosts/<host>/default.nix` lists the profiles it composes; every
profile (`modules/profiles/`) contributes module paths to the home plane, the
NixOS plane, or both. `import-tree` only assembles the flake-parts modules in
`modules/flake/`.

Key directories under `modules/`:

| Directory | Purpose |
|---|---|
| `options.nix` | `machine.*` host facts, `user.*` identity/preferences, server-profile assertion |
| `profiles/` | six opt-in profiles: `cli`, `user-base`, `ai-tools`, `linux-desktop`, `darwin-work`, `server` |
| `hosts/` | per-host `meta.nix` (facts + option values), `default.nix` (explicit profiles plus optional `nixos` host-local modules), optional `hardware.nix`, `disko.nix`, and those host-only modules |
| `home.nix` | home-manager base (fonts, nix.conf, darwin helpers) |
| `flake/` | flake-parts modules (configurations, checks, formatter) |
| `features/` | cross-platform home-manager modules (shell, editor, git, packages, theme, ai) |
| `syncthing-devices.nix` | the Syncthing device table; `features/syncthing.nix` shares the Cryptomator vault with every device in it, as ciphertext |
| `features/vault.nix` | `vault <cmd>`: mount the vault for one command, then unmount |
| `desktop/` | desktop-environment modules (niri, aerospace) |
| `nixos/` | NixOS system modules (base, desktop, networking, ssh, etc.) |
| `lib/` | helper libraries |
| `tests/` | Python unit tests for the repo's tools and shell checks |

For shared Niri/AeroSpace shortcuts, see
[`docs/desktop-parity.md`](docs/desktop-parity.md).

Television cables live with their owning feature modules: `features/tv/`
for repository navigation and `features/ai/maki/` for Maki sessions.

Cross-cutting values flow through `config.machine.*` and `config.user.*`
(options declared in `modules/options.nix`), not through `specialArgs`.
Feature options live in the module that owns them (`webProxy`, `backup`,
`immich`, `calibre`, `alerting`, …).

Operator-only steps — tokens, the admin sops key, Cloudflare objects, host
provisioning, the backup disk, public services, flake apps, and alerts — live in
[`docs/manual-steps.md`](docs/manual-steps.md). `checks.manual-steps-sync`
fails when the configuration gains an item without a matching anchor, or when
the document drifts ahead of the configuration.

The command index is the [`justfile`](justfile): run `just --list` (or bare
`just`) for checks, formatting, switches, install/bootstrap, Cloudflare
plan/apply, memory maintenance, and backup status/runs/logs.

## Installation

### Fresh machine (requires only Nix)

```sh
nix run github:smores56/nix-config#bootstrap
```

The served copy at `bootstrap.sammohr.dev` is not provisioned by this repo;
use the flake app above. It clones the repo via `ghq`, runs
`home-manager switch`, writes the committed SSH public keys, and (on NixOS)
applies the system configuration. It never logs in: it prints `gh auth status`
at the end and leaves an interactive login to the operator, while git and `gh`
take each account's sops PAT once the home is active.

### Manual

```sh
nix run github:nix-community/home-manager -- switch --flake .#<user>@<host> --no-write-lock-file
```

On NixOS, apply the system config after home-manager:

```sh
sudo nixos-rebuild switch --flake .#<host>
```

### Cloudflare Tunnel exposure

`webProxy` (declared in `modules/nixos/web-proxy.nix`) configures the tunnel
ingress: each declared service becomes `<sub>.<domain>` →
`<protocol>://127.0.0.1:<port>` (`protocol` defaults to `http`; `tcp`/`ssh`
for non-HTTP services), optionally with Cloudflare Access in front.

```nix
webProxy.services.immich = { port = 2283; };
```

`ssh`, `llm`, `memory` and `chat` require Cloudflare Access; `calibre`,
`immich`, `navidrome` and `dav` are public with their own auth, because their
clients cannot complete an Access login (DAV and the media hosts are
additionally WAF rate-limited). `access.enable` is implemented only for the
services in `webProxy.protected` (applications are hand-written in `tofu/`),
and enabling it elsewhere fails evaluation.

DNS and Access are managed by the minimal OpenTofu config in `tofu/`:

- wildcard proxied CNAME `*.sammohr.dev` → `<tunnel>.cfargotunnel.com`;
- `ssh`, `llm`, `memory`, and `chat` Access applications;
- email allow-list and service-auth policies;
- tunnel-health and expiring-service-token notifications.

Ingress stays in Nix; the tunnel itself, its credentials, and the Access
service token are operator-minted. One Cloudflare API token covers
DNS (`Zone:DNS:Edit`), Access (`Access: Apps and Policies:Edit`),
notifications (`Notifications:Edit`), and alert email (`Email Sending:Edit`).

One-time provisioning (token scopes, tunnel credentials, Email Service
onboarding, and stale-object cleanup) is operator work: see
[`docs/manual-steps.md`](docs/manual-steps.md#providers). The tunnel credentials
are the authoritative source of the tunnel UUID (`TunnelID`); no UUID is
authored in the repo. The token is read at tool time from sops and never enters
OpenTofu state.

Plan and apply from the checkout as root:

```sh
sudo nix run .#cloudflare-plan
sudo nix run .#cloudflare-apply
```

State lives in `/var/lib/cloudflare-tofu/` (0700, root-only) and is **not**
backed up: it sits outside restic's single source path (`/var/lib/data`), and
the dataset driver that once mirrored it is retired. Losing it costs the import
work, not the objects — a fresh state can be rebuilt by importing the live
account (`sudo nix run .#cloudflare-tofu -- import <address> <id>`), but nothing
regenerates it from the repo, so an apply against an empty state would create
duplicates. Import on a host with existing objects before the first apply;
`prevent_destroy` is set on the apps and policies. Stale records/apps from the
retired reconciler are removed manually first.

#### CDN terms risk

Cloudflare's terms restrict using its CDN to serve disproportionate amounts of
non-HTML content, and music streaming, original photos and book downloads are
large binary traffic over the free CDN. Accepted: one user, a self-hosted
origin, low volume. If Cloudflare objects, the mitigation is R2 (serve the
binaries from a bucket instead of the tunnel) or a paid plan.

### Personal site and keyboard redirect

`sammohr.dev` is a Cloudflare Worker with static assets serving the `docs/`
directory from `smores56/personal-site` (no build command, asset directory
`docs`). `keyboards.sammohr.dev` is a proxied placeholder record plus a Single
Redirect rule to <https://github.com/smores56/keyboards>. Both are configured
in the Cloudflare dashboard, not by this repo.

OpenTofu is deliberately not involved: the token above has no
Rulesets/Single Redirect scope, and managing one redirect would mean merging a
zone-wide ruleset.

The previous GitHub Pages build remains on `personal-site`'s `gh-pages`
branch. If the Worker fails, restore the deleted workflow from git history and point
the apex back at GitHub Pages. Purge the Cloudflare cache
after any origin switch so stale HTML does not reference missing `_app/`
chunks.

### Immich from mobile

The Immich mobile app takes a primary server URL (the tunnel hostname,
`https://immich.<domain>`) plus a **local network URL** for when the phone is on
the home LAN. smortress opens Immich's port only to its LAN subnet
(`immich.lanSources`) — point the local URL at
`http://<lan-ip>:2283`. The WAN stays tunnel-only.

Cloudflare caps a single upload at 100 MB and Immich neither chunks nor resumes,
so uploads over the tunnel fail with a 413 above that limit; the LAN URL avoids
the cap at home. Configure both URLs in the app's server settings.

### Chat (Open WebUI)

`chat.sammohr.dev` is Open WebUI behind Access and its own email/password login;
it is the phone PWA and the desktop web app. Two OpenAI-compatible backends are
declared in `modules/nixos/open-webui.nix` — local llama.cpp (keyless) and
Neuralwatt — and its state lives under `/var/lib/data/open-webui`, so restic
carries it with the durable tree. Chat is browser-only: no API key is issued.
Tool servers, the code interpreter, and the first-deployment order are in
[`docs/manual-steps.md`](docs/manual-steps.md#smortresschat).

### Calendar and contacts (Radicale)

`dav.sammohr.dev` is Radicale over the tunnel and the system of record for
VEVENT, VTODO and VCARD (`/var/lib/data/radicale`, owner-only rights). It is
public with a bcrypt htpasswd because CalDAV clients (DAVx5, khal, vdirsyncer,
macOS Calendar) cannot complete an Access login; the zone's WAF rate limit is
the brute-force control. The htpasswd and its rotation are in
[`docs/manual-steps.md`](docs/manual-steps.md#radicale-htpasswd).

### Music (Navidrome)

`music.sammohr.dev` streams `/var/lib/data/music` through the Subsonic API to
Symfonium, Feishin and Substreamer, public with Navidrome's own auth for the same
reason as DAV, and under the same per-IP rate limit. The database is
`/var/lib/data/navidrome` (backed up); the cache is regenerable and lives
outside the tree. The first account created in the web UI is the admin
([`docs/manual-steps.md`](docs/manual-steps.md#musicsammohrdev)).

### Mail (Tuta)

`sam@sammohr.dev` is a Tuta mailbox on a custom domain: one alias per forwarded
Gmail account plus a catch-all, worked through the Tuta desktop client or app —
there is no IMAP and no server-side SMTP submission, so nothing on smortress
sends or reads mail here. Host alerts go out through Cloudflare Email Sending
and only arrive. MX, SPF, the catch-all and exactly one apex `_dmarc` TXT live in
DNS beside the tunnel records; DKIM is configured from Tuta's custom-domain
settings. Forwarding confirmations, inbox rules and the DKIM selector are in
[`docs/manual-steps.md`](docs/manual-steps.md#mail-tuta).

### Syncthing and the vault

Personal files live in a Cryptomator vault: Syncthing replicates the ciphertext
(`~/Sync/vault` on laptops, `/var/lib/data/vault` on smortress) and plaintext
exists only inside an unlocked client. The device table is
`modules/syncthing-devices.nix`; one device may unlock at a time, and
`vault <cmd>` holds an unlock for the length of one command. Pairing a device,
the one-device rule, and version history are in
[`docs/manual-steps.md`](docs/manual-steps.md#syncthing-and-the-vault).

### Recovery

smortress is reached only through the Cloudflare Tunnel — there is no inbound
port — so the physical console is the out-of-band path. Everything below
assumes console access or a working client.

**No SSH from a client.** The client needs two things: the Access service
token and an SSH identity. The token is delivered per host by sops
(`/run/secrets/cloudflare-access-ssh-token` on NixOS, the sops-nix user path on
Darwin); a missing or malformed file makes `cloudflared-access` fail closed
with the path in the error. The identity is the YubiKey PIV key in the PIV agent
(`modules/features/piv.nix`); the first connection of a login session asks the
PIN once.

Then run `ssh-pub-keys` to write the committed `~/.ssh/*.pub` and refresh
`~/.ssh/allowed_signers` (every `home-manager switch` and bootstrap also run
it). The public keys are literals in `modules/lib/yubikey-keys.nix`, so a key
rotation happens there and every host picks it up at the next switch.
The work Mac permits the Google Cloud CLI's `~/.ssh/google_compute_engine`
private key as an exception to the local private-key check; this software key
remains on disk. Other private keys and symlinked keys are still rejected.

Rotating the token is a sops edit plus a redeploy: update that host's file
(`sops secrets/<host>.yaml`), switch, and reconnect. There is no cache to
restart; the wrapper reads the file on each connection.

**smortress unreachable (tunnel down, network, power).** At the console
`<tunnelName>` is `webProxy.tunnelName`:

```sh
systemctl status cloudflared-tunnel-<tunnelName>
sudo systemctl restart cloudflared-tunnel-<tunnelName>
```

If the host will not boot, reinstall from the repo with
`nix run .#install -- <hostname> root@<ip>` (see *Installing a blank machine*),
then run the `bootstrap` app.

**Cloudflare token invalid or rotated.** The running tunnel keeps serving
existing hostnames, but plan/apply fail until the token is fixed. Rotate it in
the dashboard, update `cloudflare-api-token` in `secrets/smortress.yaml`
(`sops secrets/smortress.yaml` on a machine holding the admin key), and
redeploy. Check with `sudo nix run .#cloudflare-plan`.

**Access misconfiguration.** A typo that clears `access.enable` on
`ssh`/`llm`/`memory`/`chat` fails evaluation (`modules/nixos/web-proxy.nix`), and
OpenTofu has `prevent_destroy` on those apps and policies. An Access *policy* mistake (wrong
email) still locks out the browser — fix it in OpenTofu and apply, or in the
dashboard as a break-glass step.

**sops cannot decrypt on smortress (host key lost).** The `smortress` age
recipient in `.sops.yaml` is derived from `/etc/ssh/ssh_host_ed25519_key`, so
activation cannot decrypt `secrets/smortress.yaml`. The admin identity
(`~/.config/sops/keys.age`, on a laptop only) still can: edit the secrets
there, add the replacement host recipient to `.sops.yaml`, then
`sops updatekeys secrets/smortress.yaml`.

**Admin key lost, or its passphrase lost.** No host keeps a copy, so nothing on
smortress can stand in for it and every `sops` edit fails (`sops-age-key`
reports the missing file). Recovery is a new identity, not a restore: mint
`keys.age`, swap `&admin` in `.sops.yaml`, run
`sops updatekeys secrets/smortress.yaml`, then `sops rotate --in-place
secrets/smortress.yaml` (`updatekeys` alone keeps the old data key), then delete
any leftover plaintext `~/.config/sops/age/keys.txt`. Everything the old key
could read must still be rotated. Runbook: *Admin age key (keys.age)* in
[`docs/manual-steps.md`](docs/manual-steps.md#admin-age-key-keysage).

### Service failure alerts

`alerting.enable` (implemented by `modules/nixos/alerting.nix`) sends unit
failures through Cloudflare Email Service. Every backup unit's `OnFailure`
points at the `cloudflare-email@` template. The token and non-secret
account/from/to values are read from `/run/secrets/cloudflare-api-token` and
the `alerting` options; no topic or listener runs on the host.

### Backups

restic is the driver (`modules/nixos/restic-backup.nix`): two encrypted repos —
offsite in Cloudflare R2 and on the local encrypted backup disk
(`modules/nixos/backup.nix`, LUKS) — hold the same snapshots of `/var/lib/data`,
the whole durable tree, nightly, with 14 daily / 8 weekly / 12 monthly
retention and a `restic check` after every run. The password is the
`restic-password` sops secret; every run alerts on failure. `githubBackup`
mirrors the `smores56` GitHub repos (git plus issue/PR metadata) into
`/var/lib/data/github-mirrors` with its own nightly unit, so restic carries the
mirror with everything else. Personal files live in the Cryptomator vault:
ciphertext synced by Syncthing to every device, plaintext only inside a client
(see *Syncthing and the vault*). The operator's guide — repos, restore drill,
mirror units — is
[`modules/features/backup/README.md`](modules/features/backup/README.md).

### Fingerprint enrollment

Hosts with `fingerprint.enable = true` get `services.fprintd` and the
Noctalia lock screen reader. Enroll a print once per machine after
activating the config:

```sh
fprintd-enroll        # touch the reader ~5 times; defaults to right-index-finger
fprintd-verify        # test
fprintd-list "$USER"  # confirm enrolled prints
```

The lock screen talks to fprintd over D-Bus; its PAM stack is the shared
`login` service, customized on smorespro in
`modules/hosts/smorespro/greeter.nix` (lid-gated fingerprint, PIV, one prompt).
Fingerprint auth is deliberately disabled for `sudo`/`su` (see
`modules/nixos/fprintd.nix`).

The reader can vanish after suspend/resume (Framework issue #102: its xHCI
host controller fails to re-enumerate it). `modules/nixos/fprintd.nix`
caches the host controller at boot and resets it after wake only if the
reader is missing; watch `journalctl -t fp-rebind`.

### Theme

Stylix provides one static dark theme (`rose-pine-moon`) on every host. There
is no light/dark toggle or home-manager specialisation: the palette is a
single base16 scheme, so every stylix target (kitty, zellij, …) is themed
at build time. Helix uses the bundled `rose_pine_moon` theme; lazygit keeps
its default palette.

Noctalia's `~/.local/state/noctalia/settings.toml` is left in place: it is a
sparse overlay holding only settings that deviate from the Nix base, so GUI
tweaks persist while Nix stays the base layer. The wallpaper is owned by the
`wallpapers` feature: it rsyncs the curated collection from
`smortress:/var/lib/data/wallpapers/` into `~/.cache/wallpapers`, buckets each
image by its measured aspect, and sets one
per display (Noctalia IPC on Niri, System Events on macOS), picking at random
without repeats until that aspect's set runs out. Noctalia's own rotation is
disabled so the two never fight.

### Work identity

Work is split across independent switches:

- **Per repo, on every host:** repos with a remote under one of the exact
  GitHub owners in `user.work.githubOwners` (`modules/options.nix`) get the
  work email, signing key, branch naming and PR flow, via git
  `includeIf hasconfig:remote.*.url` (`modules/features/git.nix`). It is a
  list, not a pattern, so a look-alike org never matches. Any matching remote
  counts, so a fork with a work `upstream` is a work repo. Tooling reads the
  result from `git config smores.branchTemplate` / `smores.flow`.
- **Each account is one PAT plus one signing key:** every GitHub remote uses
  HTTPS (SSH remote URLs are rewritten), and git's credential helper picks the
  owner's PAT from the request URL (`modules/features/github-credentials.nix`);
  no SSH key is registered with GitHub for git. `gh` picks by `-R`/`--repo`
  or `GH_REPO`, else the `gh api` endpoint, else the checkout's default
  remote, else the personal account; to target the other account's repo from
  elsewhere, pass `-R` or set `GH_REPO`. The work account's PAT and
  signing key exist only on the work Mac (`secrets/smoreswork.yaml`), so on
  other hosts a work repo has no token and its commits sign with the personal
  key.
- **Commit signing, per account:** every commit signs with a software key from
  sops, `github-personal-signing-key` everywhere and `github-work-signing-key`
  on the work Mac, named by `user.signingkey` (`modules/features/git.nix`;
  public halves in `modules/lib/signing-keys.nix`). Anything running as you on
  a host can sign; the YubiKey guards SSH login and `sudo`, not signatures.
- **Per host:** `aiProfile` (below) decides which model providers agents
  may use. A work clone on a personal host still gets the work git
  identity, but maki there runs on the personal providers.
- **Per host:** `workHost` (below) gives a machine that does daily work the
  employer's repo layout and shell conveniences.

### AI profiles

A home's `aiProfile` knob (`modules/options.nix`) picks which
model providers Maki may use.

- `personal` (default): maki runs on the providers in
  `modules/features/ai/providers.nix`; smortress is reached through the tunnel,
  over loopback forwards. `~/.config/maki/mcp.toml` starts the
  `memory-mcp-shim` stdio server (server name `graphiti`). The shim derives the
  project group from Maki's cwd, refuses work repositories, and forwards MCP to
  the loopback wrapper at `ports.memoryMcp` with `X-Memory-Group`/`X-Memory-Cwd`
  headers; on client machines `cloudflared-memory` supplies the Cloudflare
  Access service token. The raw Graphiti MCP runs on an internal loopback port
  in `modules/nixos/memory.nix` and is never tunneled. FalkorDB and Graphiti run
  rootless as the `memory` user; only FalkorDB's published loopback port is
  reachable. Extraction runs on
  Neuralwatt through a loopback gateway that holds the key; embeddings default
  to local bge-m3 (`memory.embedder`). The same package installs the `memory`
  CLI (`write|search|get|retry|promote|reindex|status|tombstone|ingest`) for use on a
  client or on smortress directly. The shim derives the group when Maki starts,
  so restart Maki after changing directories (`/cd` does not restart stdio
  children) and after any `mcp.toml` change.

  **Registry.** The wrapper is the only writer and holds a typed SQLite
  registry (`registry.sqlite` under the service state directory): normalized
  content, content-addressed identity, `kind`/`origin`/`origin_ref`/`valid_at`,
  verification status, promotions, and the audit trail. Identity is
  `uuid5(group, sha256(content))` and stays registry-only; the graph's own uuid
  is recorded separately. `created_at` is the write time and `queued_at` the
  queue clock (a replay resets it), so the grace, retry spacing and pending
  order measure the queue, not the age of the memory; the schema migrates
  forward in place one version at a time. A write returns after queueing, and a
  background reconciler polls FalkorDB for pending rows by exact group and
  content, resolving them to `active` with the newest matching graph uuid or,
  after a grace period and a bounded set of retries, to `failed` (retries pause
  while the model endpoint is unhealthy, and reconciler writes never overwrite a
  row that left `pending`). A pass pages by the queue clock, so a backlog larger
  than one batch is still walked instead of restarted. The MCP surface rejects a
  request body over 1 MB before the handler reads it. `memory_get` returns an episode by registry uuid, hash
  prefix, or exact `origin:origin_ref` (case-insensitive; an ambiguous hash
  prefix is an error), falling back to `global` when the caller's group has no
  match, and caps the body at 16k characters with a trailer naming the full
  length; `memory_retry` marks a row active when its extraction landed late
  instead of resubmitting it. `memory_promote` is operator-only (the `memory`
  CLI): a model-callable promote would let a prompt-injected agent publish
  project content into `global`, which every project's search includes. Search
  covers the caller's group plus `global` and tags each fact and episode with
  typed provenance joined from the registry. The node and fact searches are
  alternated by rank into one numbered list, so a fact-only answer is not buried
  behind the node list.
  A tombstone resolves every graph episode with that exact content, invalidates
  the edges they exclusively support and detaches them from shared edges, and keeps the episode nodes as
  provenance; writing the same content again revives it, and the reconciler
  binds the revived row only to a graph episode newer than the write (a second
  tombstone covers the re-extracted episode too). A row tombstoned before its
  extraction landed is swept on later passes, so that episode is invalidated
  too. Server details live in
  `modules/nixos/memory.nix`.

  **Bulk ingest.** `memory ingest {sdlc,notes,docs,sessions,all}` plans the
  personal corpus: every sdlc issue section and substantial comment, the
  markdown notes under `~/Documents` (group `global`), each personal repo's
  README/AGENTS/docs plus remote READMEs, and Maki session transcripts. Groups
  are `smores56--<repo>`, with unlabeled sdlc tasks inheriting their feature's
  `repo:` label and every `repo:` label honored; work-owned labels and work
  clones are refused. The client computes content hashes, calls the wrapper's
  loopback
  `/internal/lookup`, and submits only missing or failed episodes through
  `/internal/episodes` with explicit kind and event time (`kind=json` for JSON
  sections, `valid_at` from issue/comment timestamps, note mtime, or a doc's
  last commit). There is no client ledger: the registry is the single source of
  truth, and the run report is never read back. Those two internal routes
  require `Authorization: Bearer <token>` from `/var/lib/memory/internal.token`
  (mode 0640, group `memory`), because the tunnel reaches the wrapper as
  loopback and the peer address proves nothing. `just memory-ingest` runs
  `memory ingest all` on smortress; reports land under
  `~/.local/state/memory/`, and `--dry-run` prints the plan without writing.

  **Maki sessions.** `memory ingest sessions` reads Maki's JSONL sessions
  (`$MAKI_SESSIONS_DIR`, else the XDG state/data dirs), takes the 50 most
  recently modified by default (`--session-limit`), keeps first/last messages
  within a 24k-character transcript budget, and summarizes each one with
  `deepseek-v4.1-flash` through the same gateway (`temperature: 0`,
  `json_object`). A summary becomes one `kind=text` episode and each explicit
  decision, constraint, error, or user preference becomes its own episode, all
  with `origin=session`, `origin_ref=<session id>`, and the session header's
  `created_at` as `valid_at`. The session `cwd` picks the group with the same
  rules as everything else, and a work checkout is refused before anything is
  sent; a cwd that does not exist here is refused too, because its work markers
  cannot be checked, so a cross-machine session must be ingested where its cwd
  exists. Only the cwd's path components are checked for employer markers; text
  inside a personal checkout is not scanned for employer content. Session text
  is personal and leaves the machine for summarization; only the summary and
  extracted items are stored. An unchanged session is not re-summarized: a
  disposable cache at `$MEMORY_SESSIONS_CACHE` (default
  `~/.local/state/memory/sessions.json`) keys on session id plus the bounded
  transcript's SHA-256, so the model cannot paraphrase a session into a second
  episode; a changed transcript is summarized again. The run report records
  per-session wall time, prompt/completion tokens, and cost from
  `MEMORY_SUMMARY_PRICE_IN`/`_OUT` (USD per million, default 0.15/0.60); a
  missing `usage` block reports `unknown` rather than $0, and retries
  accumulate tokens because every paid attempt counts. `--limit` bounds
  episodes per source but not sessions: `--session-limit` bounds the session
  sample, and `memory ingest all` spends about that many summary calls.
  `memory ingest all` includes the session sample by default.
  Extraction goes through the loopback `memory-llm-proxy` to Neuralwatt: the
  gateway owns the API key and adds `reasoning_effort: "none"`, because
  graphiti-core sends no per-request control and a reasoning model would spend
  its whole token budget on reasoning and return empty content. Maki's local
  chat model is unrelated to memory. Extraction is one hosted chat call per
  episode, so a full corpus takes hours.

  **Backup and restore.** The registry is the system of record, so its snapshot
  is the backup. `memory-export.timer` runs `memory-export.service` nightly as
  root and writes `/var/lib/data/memory-export/<timestamp>/`: `registry.sqlite` from
  SQLite's online backup API (the wrapper keeps writing under WAL),
  `episodes.jsonl` with every episode's content and typed provenance,
  `manifest.json` with the schema version, per-status counts, and file
  checksums, and a best-effort `graph-<timestamp>.rdb` from one `BGSAVE`. A
  failed graph snapshot is recorded in the manifest and makes the export exit
  non-zero without invalidating the registry copy. Seven exports are kept.
  `memory restore <dir>` verifies the checksums first, refuses a schema the
  installed code cannot open, stops the memory services including FalkorDB,
  parks the live registry and replaces it atomically, and restores the graph
  snapshot only when it was taken at the same timestamp as the registry,
  restarting FalkorDB to load it. Otherwise the graph is refused and
  `memory reindex` is the replay path: one query per group collects the episode
  contents, the active rows without a matching episode are requeued and
  resubmitted at once, and the reconciler verifies each as extraction lands —
  operator-only, safe to repeat, a bounded slice per call, and a group that
  looks almost entirely missing while its graph is not empty needs `--force`.
  `memory-ingest` cannot do this because it skips rows that already succeeded.
  The export directory is inside restic's single source path, so both repos
  carry it. `just memory-export` / `just memory-restore <dir>` are the operator
  shortcuts, and the drill is in `docs/manual-steps.md`.

- `work`: maki is OpenAI-only and gets no personal providers, search, or
  memory MCP.
  The default model is configured in `modules/features/ai/maki/default.nix`.
  Store an OpenAI API key once per machine in the login keychain (the prompt
  keeps it out of shell history), then drop any earlier OAuth login, which
  maki would otherwise prefer over the key:

  ```sh
  security add-generic-password -U -a "$USER" -s maki-openai-api-key -w
  maki auth logout openai
  ```

  The `agent-sandbox` launcher reads the keychain item outside the sandbox and
  injects `OPENAI_API_KEY` into the agent; the codex CLI never sees it. Plain
  `maki` outside the sandbox does not get the key. Use `maki models` or
  `/model` to choose another OpenAI model. Claude Code continues to use its own
  subscription login.

#### Agent sandbox

`agent-sandbox <harness>` runs any agent harness with a fast, same-UID
path/privilege boundary: bwrap on Linux and `sandbox-exec` on macOS. `m` is a
shell abbreviation for `agent-sandbox maki`; plain `maki` is installed manually
in `~/.local/bin` and runs unsandboxed. The sandbox gives the agent a
read-only home plus a short write allowlist, masks credentials and the whole
`~/.config`, and exposes each account's PAT and signing key (the personal
ones bound at their `/run/secrets` paths on Linux; on macOS only the resolved
files behind `~/.local/share/github`, which on the work Mac include the work
bundle), so sandboxed git and `gh` pick the owner's token and commits sign on
every host. smortress authorizes that key with a forced `agent-ssh` command,
so remote sessions re-enter the same sandbox and `sudo` is not invocable.
The lists and backend live in `modules/lib/agent-sandbox.nix`; operator steps
are in `docs/manual-steps.md`.

### Work hosts

A home with `workHost = true` (`modules/options.nix`, derived from its
profile) applies
`user.work.flatRepos` (`modules/options.nix`);
`modules/features/work-host.nix` holds the mechanics, and no employer name
appears outside those option values.

- **Flat folder:** employer tooling and `repos get` share `flatRepos.dir` for
  the GitHub owners in `user.work.githubOwners`. `repos list` discovers those
  checkouts directly as well as ordinary repos under `codeRoot`;
  `flatRepos.envVar` is exported for the tooling. No org links are created.
- **zsh is the shell** (`user.shell` follows `workHost`; fish isn't
  enabled). HM owns `$ZDOTDIR` (`~/.config/zsh`, set from `~/.zshenv`) and
  sources the tooling-owned plain `~/.zshrc` right after compinit, so its
  PATH entries (pyenv, nvm, brew) win and its functions just work. The
  interactive layer emulates fish (`modules/features/shell.nix`).
- **Abbreviations** are declared once in `user.shellAbbrs` and rendered
  for whichever shell a host runs; pickers use `pick <tv-channel>
  <command…>`, defined for both shells.
- **Agents** get a generated `CLAUDE.md` note on the layout, and on calling
  the tooling's functions as `zsh -ic '<function> && <command>'` when their
  shell didn't load `~/.zshrc`.

Limits: the flat folder holds one checkout per name across work orgs. An
existing checkout is never overwritten by `repos get`; same-name repos from
different orgs must be handled separately. A checkout still in an org directory
must be inspected before cloning it into the flat folder. Legacy org links to
the flat folder are ignored by discovery and can be removed after checking their
consumers.

### Adding a new host

Hosts live in `modules/hosts/<hostname>/` and are discovered automatically;
adding one never edits `modules/flake/configurations.nix`.

1. `meta.nix` — a plain attrset (data, no arguments) declaring `system`,
   `username`, `nixos = true` and/or `home = true`, optional `machine`/`user`
   overrides, and option values under `homeOptions`/`nixosOptions`
   (e.g. `fingerprint.enable = true`).
2. `default.nix` — the explicit profile list this host composes
   (`../../profiles/cli.nix`, …). Profiles contribute modules to the home and
   NixOS planes. The same file may list host-local modules under `nixos` for
   one machine's concern that needs a real module (e.g. smorespro's `boot.nix`
   and `greeter.nix`). `linux-desktop` ships no display manager; a graphical
   host adds its greeter here.
3. For a NixOS host, `disko.nix` — the declarative disk layout. disko owns
   `fileSystems` for `/` and `/boot`, so `hardware.nix` omits them; pin each
   partition's `label` for stable `/dev/disk/by-partlabel` devices.
4. `hardware.nix` (kernel modules, CPU microcode) comes from
   `nixos-generate-config`. It is optional and is generated during a
   `nixos-anywhere` install. Generate it with `--no-filesystems` — disko owns
   `fileSystems`, and `nixos-anywhere` passes the flag for you.

`machine`/`user` are shared by the host's NixOS and home configs, so identity
and host facts are written once. The available configurations are the
`nixosConfigurations` / `homeConfigurations` flake outputs.

### Installing a blank machine

Commit the host's `meta.nix` + `disko.nix` (flakes only see tracked files),
then from the checkout:

```sh
nix run .#host-key -- <hostname>   # generate the host key, print its age recipient
nix run .#install -- <hostname> root@<target-ip>
```

`nixos-anywhere` kexecs the target into the NixOS installer, runs the host's
disko layout (**wiping its disks**), generates
`modules/hosts/<hostname>/hardware.nix`, and installs NixOS. It generates that
file with `--no-filesystems`, so it never redeclares what disko owns; pass the
same flag if you regenerate by hand. The generated file overwrites the
checked-in one, so re-apply any hand-added settings from git afterwards. Commit
the generated hardware config, then run the `bootstrap` app for the per-user
setup.

`host-key` writes the host's SSH key to the gitignored
`secrets/hosts/<hostname>/` and prints the sops age recipient; add it to
`.sops.yaml` as a key **and a creation rule** for `secrets/<hostname>.yaml`, then
`sops updatekeys secrets/<hostname>.yaml`, so the host decrypts its own secrets
on first boot. When that directory exists, `install` delivers it into the new
root (`/etc/ssh/...`) via `--extra-files`.

**Before reinstalling an existing machine**, run `nix run .#key-backup` and
upload the printed archive and checksum to a Bitwarden note item. It carries
the FIDO2 credential handles in `~/.config/ssh-sk` (destroyed by the wipe), the
untracked enrollment script, and the host SSH key read from
`/etc/ssh/ssh_host_ed25519_key` (one `sudo` prompt; add `--no-host-key` on a
machine with no host identity of its own). The bundle therefore carries a
plaintext private SSH key: whoever can read the Bitwarden item can impersonate the
host and decrypt its sops secrets. In the operator checkout,
`nix run .#key-restore -- <bundle> --host-key` writes `secrets/hosts/<host>/`
before `install`; after `bootstrap` on the new system,
`nix run .#key-restore -- <bundle>` puts the handles back. See
[`docs/manual-steps.md`](docs/manual-steps.md#key-backup).

### Token rotation

`bootstrap` never logs in: it ends by printing `gh auth status`, so any
interactive login is the operator's. The token inventory, scopes, minting, the
rotation checklist, and
per-provider failure behavior are documented once in
[`docs/manual-steps.md`](docs/manual-steps.md#secrets); that file also carries
the admin-key runbook. `modules/nixos/secrets.nix`
declares the keys, so a missing key fails activation — provision the tokens
before the next `nixos-rebuild switch`.
