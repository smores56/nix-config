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

This repo follows the [dendritic pattern](https://github.com/mightyiam/dendritic):
every `.nix` file under `modules/` is auto-imported by `import-tree`. No
manual `imports` lists. Place files by concern, not by host.

| Location | What goes here |
|---|---|
| `modules/options.nix` | `dotfiles.*` option declarations and computed defaults |
| `modules/home.nix` | home-manager base (fonts, nix.conf, darwin helpers) |
| `modules/features/` | cross-platform home-manager modules (shell, editor, git, packages, theme, ai) |
| `modules/desktop/` | desktop-environment modules (niri, aerospace) |
| `modules/nixos/` | NixOS system modules (networking, sound, ssh, etc.) |
| `modules/hosts/` | per-host hardware config only (filesystems, kernel modules) |
| `modules/flake/` | flake-parts modules (configurations, checks, formatter) |
| `modules/lib/` | helper libraries |
| `modules/features/ai/` | AI tool config (oh-my-pi, maki, providers, smolvm) |

### Adding a new feature

Drop a `.nix` file in the appropriate directory. It's auto-imported — no
registration needed. Read existing modules in the same directory for
patterns.

### Adding a new host config

1. `modules/hosts/<hostname>.nix` — hardware config from `nixos-generate-config`
2. `modules/flake/configurations.nix` — add `nixosConfigurations` (via
   `mkNixos`) and `homeConfigurations` (via `mkHome`) entries

## Repo-specific code quality

- **Nix style**: `nix fmt` before committing.
- **No `enable` options**: every module is imported on every host. Gate
  behavior on `config.dotfiles.*` values (e.g. `lib.mkIf isLinux`), not on
  `lib.mkEnableOption`. The dendritic pattern explicitly rejects `enable`
  options.
- **Cross-cutting values** flow through `config.dotfiles.*` options
  declared in `modules/options.nix`, not through `specialArgs`.
- **Delete dead code** — no leftover aliases, re-exports, or stale TODOs.
  If a file is unused, delete it; `import-tree` handles removals automatically.

## Verification

After any change, verify at minimum:

```sh
nix eval .#checks.x86_64-linux.eval-home-smores-smortress --apply 'x: true'
```

For changes touching NixOS modules or home-manager base:

```sh
nix eval .#checks.x86_64-linux.eval-nixos-smortress --apply 'x: true'
nix eval .#checks.x86_64-linux.eval-home-smohr-smoreswork --apply 'x: true'
nix eval .#checks.x86_64-linux.eval-nixos-smoresbook --apply 'x: true'
```

For home-manager changes, run `home-manager switch --flake .#smores@smortress`
to verify activation succeeds (not just evaluation).

## Repo conventions

- Wallpapers are LFS-tracked (`.gitattributes`).
