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

Operator-only steps (host provisioning, sops keys, Cloudflare objects, backup
datasets, public services, flake apps, alert paths) live in
`docs/manual-steps.md`. The `manual-steps-sync` check derives that inventory
from the configuration: add an anchor (`<!-- manual-step: <kind>/<id> -->`) with
real instructions for every new item, remove anchors for deleted items, and keep
the file free of `TODO`/`TBD`.

The `justfile` is the command index. Point users at `just --list` instead of
duplicating commands in prose; add a recipe there when an operation becomes a
routine.

## Where things go

Modules are composed by profiles, not auto-imported. `modules/flake/configurations.nix`
reads each host's `default.nix`, which lists profile files explicitly; each
profile contributes paths to the home plane, the NixOS plane, or both. Place
files by concern, not by host.

| Location | What goes here |
|---|---|
| `modules/options.nix` | `machine.*` host facts, `user.*` identity/preferences, and the server-profile assertion |
| `modules/profiles/` | six opt-in profiles: `cli`, `user-base`, `ai-tools`, `linux-desktop`, `darwin-work`, `server` |
| `modules/hosts/` | per-host `meta.nix` (facts + option values), `default.nix` (explicit profile list), optional `hardware.nix` and `disko.nix` |
| `modules/home.nix` | home-manager base (fonts, nix.conf, darwin helpers) |
| `modules/features/` | cross-platform home-manager modules (shell, editor, git, packages, theme, ai) |
| `modules/desktop/` | desktop-environment modules (niri, aerospace) |
| `modules/nixos/` | NixOS system modules (base, desktop, networking, ssh, etc.) |
| `modules/flake/` | flake-parts modules (configurations, checks, formatter) |
| `modules/lib/` | helper libraries |
| `modules/features/ai/` | AI tooling: assistant context, brain, maki, providers, sdlc, skills |
| `modules/features/tv/` | Television repository and worktree cables |
| `tofu/` | minimal Cloudflare DNS/Access/notification objects; run via the `cloudflare-*` flake apps |
| `modules/features/backup/` | Shell rclone driver (`backup.sh`), shell watcher, operator README, GitHub-mirror helpers and restore drill |
| `modules/desktop/aerospace/` | AeroSpace config + `aerospace-layout` |
| `tests/` | Python/Node unit tests and shell/module checks for the repo's tools (all run via flake checks) |

The optional native Slack connector lives in `modules/features/ai/slack-mcp`.
Keep desktop credentials out of source, Nix evaluation, logs, and fixtures. Its
operator-only authorization stores them in Keychain. Preserve the exact read
allowlist and in-memory-only backend caches when updating the pinned server.
Run `just test-slack` after changing it. Do not publish employer-specific skills
or workspace data with this generic integration.

Feature options live in the module that owns them (`webProxy` in
`modules/nixos/web-proxy.nix`, `backup` in `modules/nixos/backup.nix`,
`dictation` in `modules/features/dictation/`, …).

### Adding a new feature

Add a module in the appropriate directory, then list it in the profile that
owns it (`modules/profiles/<profile>.nix`). A module not listed in a profile
never evaluates.

### Adding a new host config

Hosts are discovered from `modules/hosts/*/`; adding one never edits
`configurations.nix`.

1. `modules/hosts/<hostname>/meta.nix` — a plain attrset (data, **not** a
   module: no arguments) declaring `system`, `username`, `nixos = true` and/or
   `home = true`, optional `user` overrides (machine name/system are fixed from\n`meta.nix`), and option values under
   `homeOptions`/`nixosOptions` (e.g. `fingerprint.enable = true`).
2. `modules/hosts/<hostname>/default.nix` — the explicit profile list
   (`../../profiles/cli.nix`, …) composed into this host.
3. `modules/hosts/<hostname>/disko.nix` — the declarative disk layout for a
   NixOS host. disko owns `fileSystems` for `/` and `/boot` (and `boot` when it
   manages an EF02 partition), so `hardware.nix` omits them. Pin each
   partition's `label` so the derived `/dev/disk/by-partlabel/*` devices are
   stable across reinstalls.
4. `modules/hosts/<hostname>/hardware.nix` — hardware config from
   `nixos-generate-config` (kernel modules, CPU microcode). **Optional**:
   `nixos-anywhere` generates it during the install, so a host can be authored
   without it. Always generate with `--no-filesystems` (disko owns
   `fileSystems`); `nixos-anywhere` passes the flag for you.

`nixos = true` builds `nixosConfigurations.<hostname>`; `home = true` builds
`homeConfigurations.<username>@<hostname>`. `machine`/`user` are shared by both
planes, so identity and host facts are written once.

### Provisioning a blank NixOS machine

`git add` the host's `meta.nix` + `disko.nix` first (flakes only see tracked
files), then from the checkout:

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
decrypts its own secrets on first boot.

## Repo-specific code quality

- **Nix style**: `nix fmt` before committing.
- **Imports are explicit.** Only modules listed by a host's profiles are
  evaluated; gate behavior on `machine.*`/`user.*` and on the feature's own
  options (`webProxy.enable`, `backup.enable`, …). `mkEnableOption` is for
  optional subfeatures that default to off; do not add a top-level `enable`
  for a whole module.
- **Cross-cutting values** flow through `config.machine.*` and `config.user.*`
  declared in `modules/options.nix`, not through `specialArgs`.
- **Delete dead code** — no leftover aliases, re-exports, or stale TODOs.
  If a file is unused, delete it and remove it from its profile.
- **Brain files stay employer-free**: the brain skill, digest, and its tests
  are public while the vault they serve is not. Employer specifics belong in
  the vault's `CLAUDE.md`; use placeholder ticket keys (`FOO-1`) in tests.
  `checks.brain-leak-guard` enforces this.

## Verification

`just --list` is the command index; the checks below are what its recipes wrap.

After any change, verify at minimum:

```sh
nix eval .#checks.x86_64-linux.eval-home-smores-smortress --apply 'x: true'
```

For changes touching NixOS modules or home-manager base:

```sh
nix eval .#checks.x86_64-linux.eval-nixos-smortress --apply 'x: true'
nix eval .#checks.x86_64-linux.eval-nixos-smorespro --apply 'x: true'
```

The Python tools under `modules/features/ai/` have unit tests in `tests/`,
run by the `checks` flake module. Locally: `nix run nixpkgs#python3 -- -m
unittest discover -s tests`.
Run them after touching `modules/features/ai/sdlc/`, `modules/features/ai/memory/`
(wrapper, shim, CLI, ingest, LLM proxy), maki session search, or
`modules/features/ai/brain/`.

Script checks run each `tests/<name>.sh` against tools and files from a
generated home, as the `<name>` flake check (`scriptChecks` in
`modules/flake/checks.nix`): `git-work-routing` (work vs personal identity by
remote URL), `ssh-allowed-signers`
(signature verification), `ssh-pin-askpass` (only the two PIN prompt shapes
are answered; host-key and presence prompts fail closed), `wallpapers` (aspect
buckets by measured pixels, NUL-delimited rotation without same-aspect
collisions, control-character names skipped) and `wallpapers-askpass` (only
the PIV prompt is answered; host-key, presence, and a failing Keychain read
fail closed with no PIN on stdout), `ssh-pub-keys`
(committed `.pub` keys
written and trusted, stale files replaced, a malformed key writes nothing and
exits non-zero), `ssh-no-private-keys` (a private key, including a symlink,
anywhere in `~/.ssh` fails, except the work-host gcloud key; public-only and
missing directories pass),
`worktrees-branch-template` (branch naming from
per-repo templates), `repos-routing` (flat work repo discovery and routing), `zsh-config`
(generated zsh startup files parse; only on a system with a zsh home) and
`github-mirror-probe` (the GitHub mirror rejects a stale private-repo probe and
scrubs a token-bearing origin), `github-metadata` (pgb flags and token-by-file,
manifest counts, stale/scope/count failures, and the full-pass swap),
`backup-watch` (watcher debounce/ignore/queue semantics), `backup-plain`
(copy-never-sync, versions, scoped check, markers and the stall watchdog against
local rclone remotes), and `key-bundle` (FIDO2 handle round-trip: 0600 modes,
outer and inner checksums, moved bundle, --force, public-half mismatch), and
`sshd-settings` (rendered `sshd -T`: key-only auth, verify-required, no
root/password/kbd-interactive, loopback listen, no home authorized_keys). Run them
after touching shell, git, ssh or backup settings, or
`modules/lib/repo-workflow.nix`:

```sh
nix build .#checks.aarch64-darwin.{git-work-routing,ssh-allowed-signers,ssh-pub-keys,worktrees-branch-template,repos-routing,zsh-config,github-mirror-probe}
nix build .#checks.x86_64-linux.{backup-watch,backup-plain,github-metadata,key-bundle,manual-steps-sync,sshd-settings}
```

Run `manual-steps-sync` after touching hosts, sops keys, `tofu/`, backup
datasets, `webProxy` services, flake apps, or alert paths:

```sh
nix build .#checks.x86_64-linux.manual-steps-sync
```

Run `yubikey-lists` after changing `modules/lib/yubikey-keys.nix` or an
authorized list; it checks three entries per role, parses every public key and
PIV certificate, and checks the rendered smortress authorized-key lists.

For home-manager changes, run `home-manager switch --flake .#smores@<host>`
(e.g. `.#smores@smortress` on this machine) to verify activation succeeds
(not just evaluation).

## Repo conventions

- PNG and JPEG files are LFS-tracked (`.gitattributes`).
