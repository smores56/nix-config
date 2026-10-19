# AGENTS.md

Guidance for AI coding agents working in this repository.

## Working branch

Work directly on `main`. No worktrees, feature branches, or PRs unless
explicitly asked.

## Documentation

Always keep `README.md` and `AGENTS.md` up-to-date when structure,
installation, or conventions change. Keep fragile content out of them — no
exhaustive file trees, host tables, or package lists that go stale on
every rename. Link to source files (e.g.
`modules/flake/configurations.nix`) as the source of truth for volatile
details.

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
| `modules/features/cloudflare/` | Cloudflare Tunnel DNS/Access reconciler (Python helper) + manual `cloudflare-sync` CLI |
| `modules/features/backup/` | rclone backup driver (`backup.py`) + operator README, the GitHub-mirror helper and the restore drill |
| `modules/desktop/aerospace/` | AeroSpace config + `aerospace-layout` |
| `tests/` | Python unit tests for the repo's tools plus `tests/*.sh` shell checks (all run via flake checks) |

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
   `home = true`, optional `machine`/`user` overrides, and option values under
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
Run them after touching `modules/features/ai/sdlc/`, maki session search, or `modules/features/ai/brain/`.

Script checks run each `tests/<name>.sh` against tools and files from a
generated home, as the `<name>` flake check (`scriptChecks` in
`modules/flake/checks.nix`): `git-work-routing` (work vs personal identity by
remote URL), `ssh-allowed-signers`
(signature verification), `ssh-pub-keys` (missing `.pub` files fetched from
Proton Pass and trusted, existing ones kept, a failed fetch writes nothing and
exits non-zero), `worktrees-branch-template` (branch naming from
per-repo templates), `repos-list-links` (listing through linked org dirs), `zsh-config`
(generated zsh startup files parse; only on a system with a zsh home) and
`github-mirror-probe` (the GitHub mirror rejects a stale private-repo probe and
scrubs a token-bearing origin). Run them after touching shell, git, ssh or
backup settings, or `modules/lib/repo-workflow.nix`:

```sh
nix build .#checks.aarch64-darwin.{git-work-routing,ssh-allowed-signers,ssh-pub-keys,worktrees-branch-template,repos-list-links,zsh-config,github-mirror-probe}
```

For home-manager changes, run `home-manager switch --flake .#smores@<host>`
(e.g. `.#smores@smortress` on this machine) to verify activation succeeds
(not just evaluation).

## Repo conventions

- PNG and JPEG files are LFS-tracked (`.gitattributes`).
