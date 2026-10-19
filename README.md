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
| `hosts/` | per-host `meta.nix` (facts + option values), `default.nix` (explicit profiles), optional `hardware.nix` and `disko.nix` |
| `home.nix` | home-manager base (fonts, nix.conf, darwin helpers) |
| `flake/` | flake-parts modules (configurations, checks, formatter) |
| `features/` | cross-platform home-manager modules (shell, editor, git, packages, theme, ai) |
| `desktop/` | desktop-environment modules (niri, aerospace) |
| `nixos/` | NixOS system modules (base, desktop, networking, ssh, etc.) |
| `lib/` | helper libraries |
| `tests/` | Python unit tests for the repo's tools and shell checks |

Television cables live with their owning feature modules: `features/tv/`
for repository navigation and `features/ai/maki/` for Maki sessions.

Cross-cutting values flow through `config.machine.*` and `config.user.*`
(options declared in `modules/options.nix`), not through `specialArgs`.
Feature options live in the module that owns them (`webProxy`, `backup`,
`immich`, `calibre`, `alerting`, …).

## Installation

### Fresh machine (requires only Nix)

```sh
nix run github:smores56/nix-config#bootstrap
```

The served copy (`curl -fsSL bootstrap.sammohr.dev | bash`) runs the same
script. Either way it clones the repo via `ghq`, runs `home-manager switch`,
fetches the SSH public keys from the Proton Pass vault, authenticates
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

`webProxy` (declared in `modules/options.nix`, rendered by
`modules/nixos/web-proxy.nix`) exposes services through a Cloudflare Tunnel.
Declare a service once, keyed by subdomain; it becomes
`<sub>.<domain>` → `<protocol>://127.0.0.1:<port>` (`protocol` defaults to
`http`; `tcp`/`ssh` for non-HTTP services) with a proxied DNS CNAME reconciled
on every activation and optional Cloudflare Access in front:

```nix
webProxy.services.calibre = { port = 8080; access.enable = true; };
```

One-time provisioning. Both the API token and the tunnel credentials are
secrets: they live in `secrets/smortress.yaml`, encrypted with sops-nix (age
recipients are the admin key and smortress's SSH host key), and smortress
repoints `webProxy.apiTokenFile`/`credentialsFile` at the decrypted
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
except for the protected hostnames (ssh/llm, matched by name or
origin port), whose apps are never deleted: the reconciler refuses and exits 2.

### Personal site and keyboard redirect

`sammohr.dev` is a Cloudflare Worker with static assets serving the `docs/`
directory from `smores56/personal-site` (no build command, asset directory
`docs`). `keyboards.sammohr.dev` is a proxied placeholder record plus a Single
Redirect rule to <https://github.com/smores56/keyboards>. Both are configured
in the Cloudflare dashboard, not by this repo.

`cloudflare-sync` is deliberately not involved. It reconciles tunnel CNAMEs and
Access apps, and the token documented above has Zone:DNS:Write and
Access:Apps and Policies:Write, not the Rulesets/Single Redirect scope.
Managing one redirect would mean rotating the token and merging a zone-wide
ruleset, so the rule stays in the dashboard.

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

Then run `ssh-pub-keys` to fetch any missing `~/.ssh/*.pub` and refresh
`~/.ssh/allowed_signers` (every `home-manager switch` and bootstrap also run
it). It only fetches missing files, so after replacing a key in the vault
delete its `.pub` first, e.g. `rm ~/.ssh/id_work.pub && ssh-pub-keys`.

The Access token is cached per login in
`$XDG_RUNTIME_DIR/cloudflared-access/token` (0600, tmpfs) by
`cloudflared-access-token.service`; after rotating it,
`systemctl --user restart cloudflared-access-token`. A missing cache falls back
to `pass-cli inject` (~1s slower) rather than failing.

**smortress unreachable (tunnel down, network, power).** At the console
`<tunnelName>` is `webProxy.tunnelName`:

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
`ssh`/`llm` fails evaluation (`modules/nixos/web-proxy.nix`),
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

`alerting.enable` (implemented by `modules/nixos/alerting.nix`) sends unit
failures and stale-backup warnings through Cloudflare Email Service. Every
backup unit's `OnFailure` points at the `cloudflare-email@` template, and a
five-minute freshness timer emails once per stale period. The JSON credential
lives in sops (`cloudflare-email`); no topic or listener runs on the host.

### Backups

`backup` (the backup disk; `modules/nixos/backup.nix`) plus one
`backup.datasets.<Name>` entry per dataset drives an rclone 3-2-1
pipeline — a versioned local mirror on the disk and, unless `offsite = false`,
an append-only Proton mirror — with a per-dataset timer, failure marker and Cloudflare email alert
alert. Media datasets can additionally set `onChange` to queue a run after a
debounced batch of source changes, with the timer as the fallback. smortress
backs up `Photos`/`Videos`/`Music` offsite (and change-triggered) and mirrors the
`smores56` GitHub repos locally (`githubBackup`). The operator's guide
— guarantees, trigger semantics, layout, restore and one-time prune procedures —
is [`modules/features/backup/README.md`](modules/features/backup/README.md).

### Fingerprint enrollment

Hosts with `fingerprint.enable = true` get `services.fprintd` and the
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

### Theme

Stylix provides one static dark theme (`rose-pine-moon`) on every host. There
is no light/dark toggle or home-manager specialisation: the palette is a
single base16 scheme, so every stylix target (kitty, zellij, …) is themed
at build time. Helix uses the bundled `rose_pine_moon` theme; lazygit keeps
its default palette.

Noctalia's `~/.local/state/noctalia/settings.toml` is left in place: it is a
sparse overlay holding only settings that deviate from the Nix base, so GUI
tweaks persist while Nix stays the base layer. The wallpaper is not managed
here; the desktop owns it.

### Work identity

Work is split across independent switches:

- **Per repo, on every host:** repos with a remote under the GitHub owner
  glob in `user.work` (`modules/options.nix`) get the work email,
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
`user.work.flatRepos` (`modules/options.nix`);
`modules/features/work-host.nix` holds the mechanics, and no employer name
appears outside those option values.

- **Flat folder:** employer tooling that wants every checkout in one folder
  gets it. `<codeRoot>/github.com/<owner>` for any owner matching
  `user.work.githubOwnerGlob` is a symlink to `flatRepos.dir`, so
  `repos get <owner>/<repo>` lands there while the usual path keeps working,
  and `repos list` shows each checkout once. The owner is linked on demand by
  `repos get`, so no owner name is baked into the config. `flatRepos.envVar`
  is exported for the tooling.
- **Links are created on demand** by `repos get` before a work clone. An org
  dir that already exists as a real directory is not converted; move its
  checkouts into the flat folder manually once.
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

Limits: the flat folder holds one checkout per name across all linked orgs,
and also the tooling's own state (env files, credentials), which is then
reachable under the org paths. Repo and worktree paths print under the flat
folder. Links stay when an org is dropped from the list.

### Adding a new host

Hosts live in `modules/hosts/<hostname>/` and are discovered automatically;
adding one never edits `modules/flake/configurations.nix`.

1. `meta.nix` — a plain attrset (data, no arguments) declaring `system`,
   `username`, `nixos = true` and/or `home = true`, optional `machine`/`user`
   overrides, and option values under `homeOptions`/`nixosOptions`
   (e.g. `fingerprint.enable = true`).
2. `default.nix` — the explicit profile list this host composes
   (`../../profiles/cli.nix`, …). Profiles contribute modules to the home and
   NixOS planes.
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
  `githubBackup.tokenFile`); it is root-owned, so the user's shell
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
