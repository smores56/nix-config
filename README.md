# nix-config

Personal Nix flake: NixOS and home-manager for three hosts.

| Host | What | Configurations |
|---|---|---|
| smortress | always-on NixOS server, reached only through a Cloudflare Tunnel | `nixosConfigurations.smortress`, `homeConfigurations."smores@smortress"` |
| smorespro | NixOS laptop (Niri, LUKS + Secure Boot) | `nixosConfigurations.smorespro`, `homeConfigurations."smores@smorespro"` |
| smoreswork | employer's macOS laptop, home-manager only | `homeConfigurations."sam@smoreswork"` |

## Layout

Modules are composed by profiles, not auto-imported. Each
`modules/hosts/<host>/default.nix` is a plain attrset: host facts, option
values, the `profiles` it composes, and optional host-local `homeModules` /
`nixosModules`. `modules/flake/configurations.nix` turns hosts into flake
outputs; `import-tree` only assembles the flake-parts modules in
`modules/flake/`.

| Path | Purpose |
|---|---|
| `modules/options.nix` | `machine.*` host facts and `user.*` identity/preferences |
| `modules/profiles/` | opt-in profiles: `cli`, `user-base`, `ai-tools`, `linux-desktop`, `darwin-work`, `server` |
| `modules/hosts/` | per-host `default.nix`, `disko.nix`, `hardware.nix`, `secrets.nix`, and host-only modules |
| `modules/features/` | cross-platform home-manager modules (shell, git, ssh, ai, repos, sandbox, ...) |
| `modules/nixos/` | NixOS system modules (web proxy, backup, memory, chat, ...) |
| `modules/desktop/` | Niri and AeroSpace |
| `modules/flake/` | flake-parts: configurations, checks, apps (`apps.nix`, `apps/`), formatter, nixpkgs |
| `modules/lib/` | helpers: sandbox lists, key tables, `secret-path.nix`, `hardening.nix` |
| `modules/ports.nix` | loopback port table shared by services and the tunnel |
| `pkgs/overlays.nix` | nixpkgs overlays: pins and local derivations |
| `tofu/` | Cloudflare DNS, Access and notifications |
| `tests/` | unit tests and shell checks; all run as flake checks |
| `docs/` | operator documentation |

Cross-cutting values flow through `config.machine.*` and `config.user.*`, not
`specialArgs`. A feature's options live in the module that owns it.

## Concepts

- **Work vs personal.** Repos whose remote owner is in `user.work.githubOwners`
  get the work git identity via `includeIf`. Each account has one PAT and one
  sops signing key, chosen by repo owner; the work account exists only on
  smoreswork. `user.aiProfile` (`personal` or `work`) decides which model
  providers agents may use.
- **Agent sandbox.** `agent-sandbox <harness>` runs an agent in a same-UID
  bwrap (Linux) or `sandbox-exec` (macOS) boundary. `m` abbreviates
  `agent-sandbox maki` on Linux personal hosts; smoreswork sets `m = "claude"`.
  Lists and backends: `modules/lib/agent-sandbox.nix`.
- **Memory.** smortress runs a typed SQLite registry, FalkorDB and Graphiti,
  reached over the tunnel through `memory-mcp-shim`. Extraction and embeddings
  go through a loopback Neuralwatt gateway. The `memory` CLI: `write search get
  retry promote reindex status tombstone export restore`. Server: `modules/nixos/memory.nix`.
- **Public services.** `webProxy.services` become `<name>.sammohr.dev` through
  the tunnel; `ssh`, `llm`, `memory` and `chat` sit behind Cloudflare Access.
- **Backups.** restic snapshots `/var/lib/data` to R2 and a local encrypted
  disk nightly; guide in `modules/features/backup/README.md`.
- **Secrets.** sops-nix; `secrets/<host>.yaml` is host-only, `secrets/common.yaml`
  is shared. No host holds the admin age key.

## Use

The command index is the [`justfile`](justfile): `just --list`.

```sh
nix run github:smores56/nix-config#bootstrap          # fresh machine, needs only Nix
sudo nixos-rebuild switch --flake .#<host>            # NixOS
home-manager switch --flake .#<user>@<host> --no-write-lock-file
```

## Docs

- [`docs/manual-steps.md`](docs/manual-steps.md): operator steps (hosts, secrets,
  Cloudflare, backups, services, flake apps, alerts, recovery). The
  `manual-steps-sync` check keeps it in step with the configuration.
- [`docs/key-rotation.md`](docs/key-rotation.md): YubiKey and credential rotation.
- [`docs/desktop-parity.md`](docs/desktop-parity.md): shared Niri/AeroSpace bindings.
- [`AGENTS.md`](AGENTS.md): conventions for agents working in this repo.
