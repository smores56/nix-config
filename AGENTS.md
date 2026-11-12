# AGENTS.md

Guidance for AI coding agents working in this repository.

## Working branch

This repo's `smores.flow` is `local`: feature work gets a worktree and branch,
is reviewed, and merges to `main` locally with no PR; quick fixes land
directly on `main`. Investigations are read-only. The classify step (quick fix
| investigation | feature) decides whether the SDLC funnel runs; the flow only
decides the landing gate. Explicit user instructions override the flow.

## Documentation

Always keep `README.md` and `AGENTS.md` up-to-date when structure,
installation, or conventions change. Keep fragile content out of them — no
exhaustive file trees, host tables, or package lists that go stale on
every rename. Link to source files (e.g.
`modules/flake/configurations.nix`) as the source of truth for volatile
details.

Operator-only steps (host provisioning, sops keys, Cloudflare objects, public
services, flake apps, alert paths) live in
`docs/manual-steps.md`. The `manual-steps-sync` check derives that inventory
from the configuration: add an anchor (`<!-- manual-step: <kind>/<id> -->`) with
real instructions for every new item, remove anchors for deleted items, and keep
the file free of `TODO`/`TBD`.

Credential rotation lives in `docs/key-rotation.md`: the YubiKey and machine
lifecycle, and per-secret procedures for the sops signing keys, restic, R2, the
memory token and the cloudflared tunnel.

The `justfile` is the command index. Point users at `just --list` instead of
duplicating commands in prose; add a recipe there when an operation becomes a
routine.

## Where things go

Modules are composed by profiles, not auto-imported. `modules/flake/configurations.nix`
reads each host's `default.nix`, which lists profile files explicitly; each
profile contributes paths to the home plane, the NixOS plane, or both. The same
file may list host-local modules under `homeModules` and `nixosModules` for a concern that only one
machine has (smorespro's LUKS/Secure Boot chain and greeter); those names never
reach `machine.profiles`. Place files by concern, not by host. The
`linux-desktop` profile deliberately ships no display manager: a graphical host
adds its greeter as a host-local module.

| Location | What goes here |
|---|---|
| `modules/options.nix` | `machine.*` host facts, `user.*` identity/preferences, and the server-profile assertion |
| `modules/profiles/` | seven opt-in profiles: `cli`, `user-base`, `ai-tools`, `maki`, `linux-desktop`, `darwin-work`, `server` |
| `modules/hosts/` | per-host `default.nix` (facts, option values, explicit profile list, optional `homeModules`/`nixosModules` host-local modules), optional `hardware.nix`, `disko.nix`, `secrets.nix`, and those host-only modules |
| `modules/home.nix` | home-manager base (fonts, nix.conf, darwin helpers) |
| `modules/features/` | cross-platform home-manager modules (shell, editor, git, packages, theme, ai) |
| `modules/nixos/vault-sync.nix`, `modules/syncthing-devices.nix` | The vault: one plaintext tree synced between the hosts that hold it, owned and synced by the `vault` user; the device table is a plain attrset of public device IDs |
| `modules/features/todo.nix`, `modules/nixos/todo-daemon.nix` | `todo.txt` on a size-capped ext4 image mounted at `/var/lib/data/todo`: the vault-daemon folder, the `todo-open` wrapper and `td` on both NixOS hosts |
| `modules/features/vault.nix` | `v <cmd>`: run a tool as the `vault` user against `/var/lib/data/vault`; no mount or uid mapping |
| `modules/features/brew.nix` | the work Mac's Brewfile (`just brew-bundle` applies it) |
| `modules/desktop/` | desktop-environment modules (niri, aerospace) |
| `modules/nixos/` | NixOS system modules (base, desktop, networking, ssh, etc.) |
| `modules/nixos/open-webui.nix`, `navidrome.nix` | tunnel apps with their own auth: music; Open WebUI is live only until `kanbeiSplit.cutover.enable` (T9) |
| `modules/nixos/restic-backup.nix` | restic repos, schedule, retention and the Immich db dump |
| `modules/flake/` | flake-parts modules: configurations, checks, apps (`apps.nix`, `apps/`), formatter, nixpkgs |
| `modules/lib/` | helpers: the share planner and agent-VM view/launcher, key tables, `secret-path.nix`, `hardening.nix` |
| `modules/ports.nix` | loopback port table shared by services and the tunnel |
| `pkgs/overlays.nix`, `pkgs/nanobot/`, `pkgs/letta/`, `pkgs/tutabridge.nix`, `pkgs/tuta-ics/` | nixpkgs overlays: pins and local package derivations; nanobot and Letta stay for the pre-cutover host only (T9 deletes them); tutabridge is the pinned Tuta bridge CLI and tuta-ics the read-only calendar renderer for `ingest-tuta` |
| `modules/nixos/agent-vm.nix`, `modules/features/agent-vm/` | the legacy agent VMs behind `kanbeiSplit.cutover.enable` (default off): Linux microvm guest (host module, view, firewall) and its launcher; the Mac Tart launcher. `a` is plain `maki`/`claude`; shared facts in `modules/lib/agent-vm.nix`, planner in `modules/lib/share_planner.py` and the host-side verifier in `modules/lib/agent-vm-verify.sh`. Deleted in the T9 follow-up |
| `modules/nixos/cluster-vm.nix`, `modules/lib/vm-host.nix` | the smortress-only k3s guest: qemu microVM, gVisor containerd runtime, virtiofs data shares and the host's tap/firewall/token staging; shared per-guest facts live in `modules/lib/vm-host.nix` |
| `modules/nixos/kanbei-vm.nix` | the smortress-only private-data guest: qemu microVM with the 3090 by VFIO, a LUKS2 data volume sealed to a per-VM swtpm, root-only host state and a freeze-then-snapshot backup; behind `kanbeiVm.enable` (`docs/kanbei-vm.md`) |
| `modules/nixos/kanbei-phone.nix`, `modules/lib/phone-pipeline.nix`, `modules/lib/phone/`, `mobile/` | the phone pipeline: the phone's receive-encrypted Syncthing folder on the host, the guest's password contract and hourly `syncthing decrypt`, the exact SMS Import/Export settings and validator, and the INTERNET-less healthconnect-export fork with its manifest gate (`docs/kanbei-phone.md`) |
| `modules/nixos/kanbei-inference.nix`, `modules/lib/kanbei-inference.nix` | the kanbei guest's llama.cpp lanes: one GPU chat server on a unified q8_0 KV pool, CPU embeddings/rerank servers, the lane/VRAM math in one attrset and its manifest + fetch tool; eval harness in `tests/inference/` (`docs/kanbei-inference.md`) |
| `modules/nixos/kanbei-access.nix`, `modules/nixos/kanbei-guest-access.nix`, `modules/lib/kanbei/` | the kanbei access path: loopback TCP→vsock relay under its own uid, host ACME responder, private hostname route, in-guest TLS + static CSP shell with a JSON API and WebAuthn challenge stub (`docs/kanbei-access.md`) |
| `modules/nixos/ingest-vm.nix`, `modules/lib/ingest-vm.nix`, `modules/lib/ingest/`, `modules/lib/search/` | the Firecracker ingest plane: one guest per source with a read-only secret block device and a vsock writer, the hostname/SNI proxy and allowlist resolver, freshness heartbeats, the cluster-digest host writer, root-only logs and `kanbei-ingest-verify` (`docs/kanbei-ingest.md`; per-source specifics in `docs/kanbei-ingest-tuta.md`, `-finance.md`, `-brave.md` and `-immich.md`). The `search` guest's capped query channel (DLP, length cap, persisted limiter, CPU Granite Guardian, stripped results, planted suite) lives in `modules/lib/search/` and `docs/kanbei-search.md` |
| `modules/features/ai/` | AI tooling: assistant context, harvest, Claude settings merge, maki, memory, providers, sdlc, skills. `memory/service.nix` is the one memory service description; `modules/nixos/memory.nix` and `memory/darwin.nix` render it |
| `modules/features/tv/`, `modules/features/repos/` | Television repository and worktree cables; the `repos`/`worktrees` CLIs they call |
| `tofu/` | minimal Cloudflare DNS/Access/notification objects plus the `recovery` Pages project and its DNS record; run via the `cloudflare-*` flake apps |
| `recovery/` | the public recovery page (Deno, plain ESM) and its operator scripts: blob builder, sentinel, smoke; published by `.github/workflows/recovery.yml` |
| `modules/features/backup/` | Operator README and the retired GitHub-mirror helpers; the live mirror is the `homelabs-platform` CronJob |
| `modules/desktop/aerospace/` | AeroSpace config + `aerospace-layout` |
| `tests/` | Python unit tests and shell/module checks for the repo's tools (all run via flake checks) |

Feature options live in the module that owns them (`webProxy` in
`modules/nixos/web-proxy.nix`, `backup` in `modules/nixos/backup.nix`,
`dictation` in `modules/features/dictation/`, …). A module's presence in a
profile is its on switch.

### Adding a new feature

Add a module in the appropriate directory, then list it in the profile that
owns it (`modules/profiles/<profile>.nix`). A module not listed in a profile
never evaluates.

### Adding a new host config

Hosts are discovered from `modules/hosts/*/`; adding one never edits
`configurations.nix`.

1. `modules/hosts/<hostname>/default.nix` — a plain attrset (data, **not** a
   module: no arguments) declaring `system`, `username`, `nixos = true` and/or
   `home = true`, optional `user` overrides, option values under
   `homeOptions`/`nixosOptions` (e.g. `sudoKey.enable = true`), the explicit
   `profiles` list (`../../profiles/cli.nix`, …) composed into this host, and
   optional host-local modules (`nixosModules = [ ./boot.nix ]`,
   `homeModules = [ … ]`) that only this machine evaluates. Use those for
   host-scoped configuration that needs a real module (`lib.mkForce`, `imports`
   of a flake input's module), which the option sets cannot express.
2. `modules/hosts/<hostname>/disko.nix` — the declarative disk layout for a
   NixOS host. disko owns `fileSystems` for `/` and `/boot` (and `boot` when it
   manages an EF02 partition), so `hardware.nix` omits them. Pin each
   partition's `label` so the derived `/dev/disk/by-partlabel/*` devices are
   stable across reinstalls.
3. `modules/hosts/<hostname>/hardware.nix` — hardware config from
   `nixos-generate-config` (kernel modules, CPU microcode). **Optional**:
   `nixos-anywhere` generates it during the install, so a host can be authored
   without it. Always generate with `--no-filesystems` (disko owns
   `fileSystems`); `nixos-anywhere` passes the flag for you.

`nixos = true` builds `nixosConfigurations.<hostname>`; `home = true` builds
`homeConfigurations.<username>@<hostname>`. `system`/`username` and `user` are
shared by both planes, so identity and host facts are written once.

### Provisioning a blank NixOS machine

`git add` the host's whole directory (`default.nix`, `disko.nix`, any host-local
modules) first — flakes only see tracked files, and `install` rejects untracked
files there. Then from the checkout:

```
nix run .#host-key -- <hostname>   # generate the host key, print its age recipient
nix run .#install -- <hostname> root@<target-ip>
```

`nixos-anywhere` kexecs the target into the NixOS installer, runs the host's
disko layout (**wiping its disks**), generates
`modules/hosts/<hostname>/hardware.nix`, and installs. It generates that file
with `--no-filesystems`, so it never redeclares the `fileSystems` disko owns
(pass the same flag if you regenerate by hand). The generated file overwrites
the checked-in one, so re-apply any hand-added settings from git afterwards.
Commit the generated hardware config, then run the `bootstrap` app for the
per-user setup.

`host-key` writes the host's SSH key to the gitignored
`secrets/hosts/<hostname>/` and prints the sops age recipient (add it to
`.sops.yaml`, then `sops updatekeys`). When that directory exists, `install`
delivers it into the new root (`/etc/ssh/...`) via `--extra-files`, so the host
decrypts its own secrets on first boot. For an existing machine, `key-backup`
archives the live key and `key-restore --host-key` recreates that directory
before `install`.

## Repo-specific code quality

- **Nix style**: `nix fmt` before committing.
- **Imports are explicit.** Only modules listed by a host's profiles or its
  `nixos` list are evaluated; gate behavior on `machine.*`/`user.*` and on the
  feature's own options (`exposeSsh.enable`, `backup.luks.enable`, …).
  `mkEnableOption` is for optional subfeatures that default to off; do not add
  a top-level `enable` for a whole module.
- **Cross-cutting values** flow through `config.machine.*` and `config.user.*`
  declared in `modules/options.nix`, not through `specialArgs`.
- **Delete dead code** — no leftover aliases, re-exports, or stale TODOs.
  If a file is unused, delete it and remove it from its profile.
- **Harvest files stay employer-free**: the harvester, the brain skill, and
  their tests are public while the memory they fill is not. Employer
  specifics come from options and the user's own tools; use placeholder
  ticket keys (`FOO-1`) in tests. `checks.brain-leak-guard` enforces this.

## Verification

`just --list` is the command index. After any change, evaluate every host it
can affect:

```sh
just verify-home smores smortress   # also smores smorespro, sam smoreswork
just verify-nixos smortress         # also smorespro
```

`just test` runs the Python unit suite (the `unit-tests` check) after touching
`modules/features/ai/` or maki session search; `just check-build`
builds every check for the current system.

Checks are organised in `modules/flake/checks.nix`: `scriptChecks` runs each
`tests/<name>.sh` against tools and files from a generated home as the `<name>`
check, alongside the `eval-*` and unit-test checks. List them with:

```sh
nix eval --json .#checks.x86_64-linux --apply builtins.attrNames
```

Some checks are Linux-only (`manual-steps-sync`, `pam-auth-gates`,
`sshd-settings`, `github-metadata`, `memory-export-restore`, `ssh-askpass`,
`agent-vm-linux-static`, `eval-nixos-*`); build the one that matches
what you touched, e.g. `nix build .#checks.aarch64-darwin.git-work-routing`.

Run `manual-steps-sync` after touching hosts, sops keys, `tofu/`, `webProxy`
services, flake apps, or alert paths:

```sh
nix build .#checks.x86_64-linux.manual-steps-sync
```

Run `yubikey-lists` after changing `modules/lib/yubikey-keys.nix`,
`modules/lib/signing-keys.nix`, or an authorized list; it checks three entries per role, parses every public key and
PIV certificate, and checks the rendered smortress authorized-key lists.

For home-manager changes, run `home-manager switch --flake .#smores@<host>`
(e.g. `.#smores@smortress` on this machine) to verify activation succeeds
(not just evaluation).

## Repo conventions

- PNG and JPEG files are LFS-tracked (`.gitattributes`).
