# nix-config

Personal Nix configuration for macOS and NixOS machines, managed with
[flakes](https://nixos.wiki/wiki/Flakes) and
[home-manager](https://github.com/nix-community/home-manager).

## Structure

This repo follows the **[dendritic pattern](https://github.com/mightyiam/dendritic)**:
files under `modules/` are self-contained top-level modules, auto-discovered
via [import-tree](https://github.com/vic/import-tree) (a few entry points and
pure-function helpers are listed explicitly). No manual per-module `imports`
lists.

Key directories under `modules/`:

| Directory | Purpose |
|---|---|
| `options.nix` | `dotfiles.*` option declarations and computed defaults |
| `home.nix` | home-manager base (fonts, nix.conf, darwin helpers) |
| `flake/` | flake-parts modules (configurations, checks, formatter) |
| `features/` | cross-platform home-manager modules (shell, editor, git, packages, theme, ai) |
| `desktop/` | desktop-environment modules (niri, aerospace) |
| `nixos/` | NixOS system modules (base, desktop, networking, ssh, etc.) |
| `hosts/` | per-host directory: `meta.nix` (host knobs; auto-discovered) + optional `hardware.nix` (nixos-generate-config) and `disko.nix` (declarative disks) |
| `lib/` | helper libraries |
| `tests/` | Python unit tests for the repo's tools (sdlc, maki, brain, photobucket, cloudflare, backup, immich, aerospace-layout), and shell checks |

Television cables live with their owning feature modules: `features/tv/`
for repository navigation and `features/ai/maki/` for Maki sessions.

Cross-cutting values flow through `config.dotfiles.*` options declared in
`modules/options.nix`, not through `specialArgs` pass-through. Every
module reads what it needs from `config.dotfiles`, and each host config
sets its own options in `mkHome`/`mkNixos` calls.

## Installation

### Fresh machine (requires only Nix)

```sh
nix run github:smores56/nix-config#bootstrap
```

The served copy (`curl -fsSL bootstrap.sammohr.dev | bash`) runs the same
script. Either way it clones the repo via `ghq`, runs `home-manager switch`,
materialises the SSH public keys from the Proton Pass agent, authenticates
GitHub, and (on NixOS) applies the system configuration.

### Manual

```sh
nix run github:nix-community/home-manager -- switch --flake .#<user>@<host> --no-write-lock-file
```

On NixOS, apply the system config after home-manager:

```sh
sudo nixos-rebuild switch --flake .#<host>
```

### Cloudflare Tunnel exposure

`dotfiles.webProxy` (declared in `modules/options.nix`, rendered by
`modules/nixos/web-proxy.nix`) exposes services through a Cloudflare Tunnel.
Declare a service once, keyed by subdomain; it becomes
`<sub>.<domain>` → `<protocol>://127.0.0.1:<port>` (`protocol` defaults to
`http`; `tcp`/`ssh` for non-HTTP services) with a proxied DNS CNAME reconciled
on every activation and optional Cloudflare Access in front:

```nix
webProxy.services.ntfy = { port = 2586; access.enable = true; };
```

One-time provisioning. Both the API token and the tunnel credentials are
secrets: they live in `secrets/smortress.yaml`, encrypted with sops-nix (age
recipients are the admin key and smortress's SSH host key), and smortress
repoints `dotfiles.webProxy.apiTokenFile`/`credentialsFile` at the decrypted
files (`modules/nixos/secrets.nix`). Nothing enters the Nix store.

- Create a Cloudflare API token scoped to the apex zone with
  **Zone:DNS:Write** and **Access: Apps and Policies:Write**, and the tunnel's
  credentials JSON.
- Store them as `cf-api-token` and `cloudflared-credentials` with
  `sops secrets/smortress.yaml`.
- The tunnel credentials are the authoritative source of the tunnel UUID
  (`TunnelID`); no UUID is authored anywhere in the repo. `tunnelName` is only
  a label and must be a non-UUID string.

`modules/nixos/cloudflare-sync.nix` runs the reconciler at boot and after every
activation. Dry-run it with `sudo cloudflare-sync --check` — it prints the diff
(created / updated / adopted / deleted / unchanged) and exits 0 when clean, 1
on drift, and 2 on an API, spec, or safety error (a permission problem or a
refused protected-hostname deletion is never mistaken for drift). DNS is
**adopt-never-delete**: a matching CNAME is left in place and nothing is
removed; a CNAME at a declared name pointing elsewhere is **updated** to the
tunnel (it logs the previous target). Access applications are the one exception
— disabling `access.enable` deletes the app, making the endpoint public again —
except for the protected hostnames (ssh/llm/searx/ntfy/chat, matched by name or
origin port), whose apps are never deleted: the reconciler refuses and exits 2.

### Immich from mobile

The Immich mobile app takes a primary server URL (the tunnel hostname,
`https://immich.<domain>`) plus a **local network URL** for when the phone is on
the home LAN. smortress opens Immich's port only to its LAN subnet
(`dotfiles.immich.lanSources`) — point the local URL at
`http://<lan-ip>:2283`. The WAN stays tunnel-only.

Cloudflare caps a single upload at 100 MB and Immich neither chunks nor resumes,
so uploads over the tunnel fail with a 413 above that limit; the LAN URL avoids
the cap at home. Configure both URLs in the app's server settings.

### Chat UI

`chat.<domain>` serves [Open WebUI](https://openwebui.com) — a single-user chat
front end, declared by `dotfiles.chat` on smortress (`modules/nixos/chat.nix`).
It listens on loopback only; the tunnel publishes it behind Cloudflare Access (it
is a protected hostname, so the ingress cannot exist without `access.enable`),
with Open WebUI's own login as the second gate. The first visit offers sign-up;
that account becomes admin. Sign-up is pinned off (`ENABLE_SIGNUP=False`) — the
first admin is exempt from that flag, so the initial account can still be created.

Two OpenAI-compatible upstreams are wired: the hosted Neuralwatt API
(`neuralwatt.<model>`, default `neuralwatt.deepseek-v4.1-flash`) and the local
`llama.cpp` (`local.qwen3.8-27b`). Web search uses the co-located SearXNG over
loopback; document RAG embeds locally with `all-MiniLM-L6-v2` (Neuralwatt has no
embeddings API); and the code interpreter drives a `jupyter-sandbox` systemd unit
on loopback, token-authenticated from sops. The sandbox runs arbitrary code as a
`DynamicUser` with `MemoryMax=4G`; it is never exposed through the tunnel, but its
network egress is deliberately unrestricted.

The Neuralwatt key, the Open WebUI session secret, and the Jupyter token are sops
secrets (`neuralwatt-api-key`, `open-webui-secret-key`, `jupyter-token`), rendered
into root-owned env files that systemd reads before dropping privileges.

New chats start with web search and the code interpreter already toggled on: the
per-chat toggles honour a model's `defaultFeatureIds` only when the matching
capability is set, so `DEFAULT_MODEL_METADATA` supplies both for every model.

Config is **env-authoritative** (`ENABLE_PERSISTENT_CONFIG=False`). Open WebUI's
`PersistentConfig` seeds a DB row only when it is absent, so an env change after
first launch is otherwise ignored — a stale empty `models.default_metadata` row is
exactly that case. The trade-off: config edited in the admin UI does not survive a
restart, and neither does state the app mutates at runtime (hence the pinned
`ENABLE_SIGNUP`). Change `modules/nixos/chat.nix` instead.

### Recovery

smortress is reached only through the Cloudflare Tunnel — there is no inbound
port — so the physical console is the out-of-band path. Everything below
assumes console access or a working client.

**No SSH from a client.** The client needs two things from Proton Pass: the
Access service token (resolved by the `cloudflared-access` wrapper) and an SSH
identity from the agent. If `pass-cli` has logged out:

```sh
PROTON_PASS_KEY_PROVIDER=fs pass-cli login --interactive
ssh-add -L                                    # should list the identity
systemctl --user restart proton-pass-agent    # macOS: launchctl kickstart -k gui/$(id -u)/org.nix-community.home.proton-pass-agent
```

Then re-run `nix run github:smores56/nix-config#bootstrap` to re-materialise
`~/.ssh/*.pub`.

**smortress unreachable (tunnel down, network, power).** At the console
`<tunnelName>` is `dotfiles.webProxy.tunnelName`:

```sh
systemctl status cloudflared-tunnel-<tunnelName>
sudo systemctl restart cloudflared-tunnel-<tunnelName>
```

If the host will not boot, reinstall from the repo with
`nix run .#install -- <hostname> root@<ip>` (see *Installing a blank machine*),
then run the `bootstrap` app.

**Cloudflare token invalid or rotated.** The reconciler runs at boot and after
each activation and exits 2 — not drift — when the API fails; the running
tunnel keeps serving existing hostnames, but DNS/Access stop reconciling.
Rotate the token in the dashboard, update `cf-api-token` in
`secrets/smortress.yaml` (`sops secrets/smortress.yaml`), and redeploy. Check
with `sudo cloudflare-sync --check`.

**Access misconfiguration.** A typo that clears `access.enable` on
`ssh`/`llm`/`searx`/`ntfy`/`chat` fails evaluation (`modules/nixos/web-proxy.nix`),
and the reconciler refuses to delete those apps even when asked
(`PROTECTED_SUBDOMAINS` in `modules/features/cloudflare/cloudflare_sync.py`).
An Access *policy* mistake (wrong email) still locks out the browser — fix it
in the Cloudflare dashboard.

**sops cannot decrypt (host key lost).** The `smortress` age recipient in
`.sops.yaml` is derived from `/etc/ssh/ssh_host_ed25519_key`; losing that key
means `secrets/smortress.yaml` cannot be decrypted. Restore the key, or
re-key: add a fresh recipient to `.sops.yaml` and re-encrypt with the admin
age key.

### Service failure alerts

`dotfiles.notify` (declared in `modules/options.nix`, implemented by
`modules/nixos/notify.nix`) runs a self-hosted [ntfy](https://ntfy.sh) listener
on loopback and a templated handler that any unit can be pointed at:

```nix
systemd.services.my-thing.onFailure =
  lib.optional config.dotfiles.notify.enable config.dotfiles.notify.unit;
```

Gate on the option (and read `dotfiles.notify.unit`) instead of hardcoding the
unit name: a host that has not enabled notify has no such template, and a
dangling `onFailure` reference fails activation. The handler journals the
failing invocation's last lines and publishes them to the loopback listener, so
alerts arrive even without the public `ntfy.<domain>` exposure — that only adds
browser access, and it is gated behind Cloudflare Access (see
`modules/nixos/notify.nix` for the assertion enforcing this).

The topic is the only secret and never enters the Nix store; it is generated
once at `/var/lib/ntfy-alert/topic` (mode 0600, dir 0700). Read and poll it
from the host:

```sh
sudo cat /var/lib/ntfy-alert/topic                     # the topic
curl -s "http://127.0.0.1:2586/$(sudo cat /var/lib/ntfy-alert/topic)"   # backlog
```

Known limits: ntfy runs on this host, so it cannot report the host itself
being down; and the mobile app cannot pass Cloudflare Access, so consume
alerts in the browser.

### Backups

`dotfiles.backup` (the backup disk; `modules/nixos/backup.nix`) plus one
`dotfiles.backup.datasets.<Name>` entry per dataset drives an rclone 3-2-1
pipeline — a versioned local mirror on the disk and, unless `offsite = false`,
an append-only Proton mirror — with a per-dataset timer, failure marker and ntfy
alert. Media datasets can additionally set `onChange` to queue a run after a
debounced batch of source changes, with the timer as the fallback. smortress
backs up `Photos`/`Videos`/`Music` offsite (and change-triggered) and mirrors the
`smores56` GitHub repos locally (`dotfiles.githubBackup`). The operator's guide
— guarantees, trigger semantics, layout, restore and one-time prune procedures —
is [`modules/features/backup/README.md`](modules/features/backup/README.md).

### Fingerprint enrollment

Hosts with `dotfiles.fingerprint = true` get `services.fprintd` and the
Noctalia lock screen reader. Enroll a print once per machine after
activating the config:

```sh
fprintd-enroll        # touch the reader ~5 times; defaults to right-index-finger
fprintd-verify        # test
fprintd-list "$USER"  # confirm enrolled prints
```

The lock screen talks to fprintd over D-Bus, so it needs no PAM setup.
Fingerprint auth is deliberately disabled for `sudo`/`su` (see
`modules/nixos/fprintd.nix`).

The reader can vanish after suspend/resume (Framework issue #102: its xHCI
host controller fails to re-enumerate it). `modules/nixos/fprintd.nix`
caches the host controller at boot and resets it after wake only if the
reader is missing; watch `journalctl -t fp-rebind`.

### Light/dark theming

The **native appearance setting is the source of truth** — macOS Appearance
(System Settings), or Noctalia's theme toggle on Niri. Nothing in this config
writes that setting; it only follows it.

- Both polarities are declared as home-manager [specialisations](https://nixos.wiki/wiki/Home_Manager),
  so switching re-themes every stylix target at once (kitty, firefox, zellij, …).
- The change is event-driven, never polled: `dark-mode-notify` (macOS) and
  Noctalia's `started` / `theme_mode_changed` hooks (Linux) call
  `modules/lib/theme-apply.nix`, which activates the matching specialisation and
  no-ops when it is already active.
- Noctalia's `~/.local/state/noctalia/settings.toml` is left in place: it is a
  sparse overlay holding only settings that deviate from the Nix base, so your
  toggle (and any other GUI tweak) persists while Nix stays the base layer.
- `dotfiles.polarity` is only the pre-sync default used until the first event.
  Per-app extras stylix does not cover (helix, lazygit) are rewritten by the
  activation hook in `modules/features/theme.nix`.

### Work identity

Work is split across independent switches:

- **Per repo, on every host:** repos with a remote under the GitHub owner
  glob in `dotfiles.work` (`modules/options.nix`) get the work email,
  signing key, ssh route (`~/.ssh/config.work`, work key only), branch
  naming and PR flow, via git `includeIf hasconfig:remote.*.url`
  (`modules/features/git.nix`). Any matching remote counts, so a fork with a
  work `upstream` is a work repo. Tooling reads the result from
  `git config smores.branchTemplate` / `smores.flow`.
- **Per host:** `aiProfile` (below) decides which model providers agents
  may use. A work clone on a personal host still gets the work git
  identity, but maki there runs on the personal providers.
- **Per host:** `workHost` (below) gives a machine that does daily work the
  employer's repo layout and shell conveniences.

### AI profiles

A home's `aiProfile` knob (`modules/flake/configurations.nix`) picks which
model providers Maki may use.

- `personal` (default): maki runs on the providers in
  `modules/features/ai/providers.nix`; smortress is reached through the tunnel,
  over loopback forwards.
- `work`: maki is OpenAI-only and gets no personal providers or search.
  The default model is configured in `modules/features/ai/maki/default.nix`.
  Sign in once per machine using your ChatGPT/Codex account:

  ```sh
  maki auth login openai
  ```

  Choose ChatGPT login for subscription access. Maki stores and refreshes its
  own credentials; an existing Codex CLI login does not replace this step.
  Use `maki models` or `/model` to choose another available OpenAI model.
  The wrapper clears `OPENAI_BASE_URL` so work prompts go directly to OpenAI.
  Claude Code continues to use its own subscription login.

### Work hosts

A home with `workHost = true` (`modules/flake/configurations.nix`) applies
`dotfiles.work.flatRepos` (`modules/options.nix`);
`modules/features/work-host.nix` holds the mechanics, and no employer name
appears outside those option values.

- **Flat folder:** employer tooling that wants every checkout in one folder
  gets it. `<codeRoot>/github.com/<owner>` for any owner matching
  `dotfiles.work.githubOwnerGlob` is a symlink to `flatRepos.dir`, so
  `repos get <owner>/<repo>` lands there while the usual path keeps working,
  and `repos list` shows each checkout once. The owner is linked on demand by
  `repos get`, so no owner name is baked into the config. `flatRepos.envVar`
  is exported for the tooling.
- **Links are created on switch** for empty dirs (and `.DS_Store`-only ones)
  among owners already present. An org dir that already holds checkouts is
  reported, never moved; run `work-repo-links --migrate` to move its entries
  into the flat folder (refusing name collisions, repairing worktrees) and
  link it.
- **zsh is the shell** (`dotfiles.shell` follows `workHost`; fish isn't
  enabled). HM owns `$ZDOTDIR` (`~/.config/zsh`, set from `~/.zshenv`) and
  sources the tooling-owned plain `~/.zshrc` right after compinit, so its
  PATH entries (pyenv, nvm, brew) win and its functions just work. The
  interactive layer emulates fish (`modules/features/shell.nix`).
- **Abbreviations** are declared once in `dotfiles.shellAbbrs` and rendered
  for whichever shell a host runs; pickers use `pick <tv-channel>
  <command…>`, defined for both shells.
- **Agents** get a generated `CLAUDE.md` note on the layout, and on calling
  the tooling's functions as `zsh -ic '<function> && <command>'` when their
  shell didn't load `~/.zshrc`.

Limits: the flat folder holds one checkout per name across all linked orgs,
and also the tooling's own state (env files, credentials), which is then
reachable under the org paths. Repo and worktree paths print under the flat
folder. Links stay when an org is dropped from the list.

### Adding a new host

Hosts live in `modules/hosts/<hostname>/` and are discovered automatically;
adding one never edits `modules/flake/configurations.nix`.

1. Add `modules/hosts/<hostname>/meta.nix` — a plain attrset (data, no
   arguments) declaring `system`, `username`, whether to build a NixOS config
   (`nixos = true`) and/or a home config (`home = true`), and a `dotfiles`
   attrset of the host's knobs (see `modules/options.nix`).
2. For a NixOS host, add `modules/hosts/<hostname>/disko.nix` — the declarative
   disk layout. disko owns `fileSystems` for `/` and `/boot`, so `hardware.nix`
   omits them; pin each partition's `label` for stable `/dev/disk/by-partlabel`
   devices.
3. `hardware.nix` (kernel modules, CPU microcode) comes from
   `nixos-generate-config`. It is optional and is generated during a
   `nixos-anywhere` install (see *Installing a blank machine*). Generate it with
   `--no-filesystems` — disko owns `fileSystems`, and `nixos-anywhere` passes
   the flag for you.

The `dotfiles` attrset is shared by the host's NixOS and home configs; each
reads the knobs it knows, so a value is written once. The available
configurations are the `nixosConfigurations` / `homeConfigurations` flake
outputs.

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

### Provisioning PATs (headless login)

`bootstrap` logs in non-interactively when the host's sops secrets hold the
tokens. `modules/nixos/secrets.nix` declares `github-key-pat`,
`proton-pass-pat` and `github-repo-pat`; add them to the encrypted file
**before** the next `nixos-rebuild switch`, or activation fails on the missing
key:

```sh
nix-shell -p sops --run 'sops secrets/smortress.yaml'
# add github-key-pat: <token>, proton-pass-pat: <pst_...::key>, github-repo-pat: <token>
```

- `github-key-pat` needs permission to register SSH keys: a **classic** token with
  `write:public_key` and `write:ssh_signing_key`, or a **fine-grained** token
  with the account permissions "Git SSH keys: write" and "SSH signing keys:
  write" (fine-grained tokens do not advertise OAuth scopes, so `bootstrap`
  trusts their configured permissions). `gh auth login --with-token` uses it.
- `proton-pass-pat` is a `pass-cli` personal access token; `pass-cli login` uses
  it. Scope it to the **Hosting** and **Identity** vaults at read-only
  permission: bootstrap only reads SSH keys and the Access service token, so a
  narrow scope bounds what a leaked token exposes. The *token* is long-lived
  (see "Rotating the PATs"), but each *login session* it grants lasts only ~2 h
  and cannot be locked, so a headless host re-logs-in on each `bootstrap` run
  (an interactive `fs` session persists longer).
- `github-repo-pat` has `repo` scope (classic) and is read **only** by the root
  GitHub-backup service (`modules/nixos/github-backup.nix`, via
  `dotfiles.githubBackup.tokenFile`); it is root-owned, so the user's shell
  cannot read it. `bootstrap` never touches it. Classic `repo` grants read/write
  to every private repo the account can reach, including org repos, while the
  mirror only reads; fine-grained tokens cannot read wikis, so `--clone-wiki`
  would silently omit them. Keep this token root-only.

#### Rotating the PATs

The tokens expire and need periodic replacement — `proton-pass-pat` has a
**maximum lifetime of one year** (a Proton Pass limit), and the GitHub PATs
expire per their own setting. Replace each before it lapses:

1. Issue a replacement — Proton Pass → Settings → Access tokens (scope: Hosting
   + Identity, read-only), GitHub → Developer settings → tokens for
   `github-key-pat` (classic: the two scopes above; fine-grained: the two account
   permissions above), or a `repo`-scoped classic token for `github-repo-pat`.
2. Update the value: `nix-shell -p sops --run 'sops secrets/<host>.yaml'`.
3. Commit, then `nixos-rebuild switch` on every host holding the token, so
   sops-nix redeploys `/run/secrets/*`.

A lapsed token degrades differently per provider:

- `proton-pass-pat` — `pass-cli login` fails, `bootstrap` warns and continues;
  log in interactively afterwards.
- `github-key-pat` — `gh auth login --with-token` rejects it and `bootstrap` **fails
  hard**. Blank the secret (and rebuild) to fall back to the device-code flow.
- `github-repo-pat` — the nightly GitHub mirror fails until a valid token is back
  in place. A token that is valid but has lost `repo` scope is caught by the
  probe, which requires a known-private repo to be refreshed on every run.
