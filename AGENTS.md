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
most `.nix` files under `modules/` are auto-imported by `import-tree`, which
scans `modules/flake` (from `flake.nix`) and the `features`/`desktop`/`nixos`
subtrees (from `modules/flake/configurations.nix`). A few entry points and
pure-function helpers (`modules/options.nix`, `modules/home.nix`,
`modules/features/ai/providers.nix`, `modules/lib/*`) are listed or imported
explicitly. Place files by concern, not by host.

| Location | What goes here |
|---|---|
| `modules/options.nix` | `dotfiles.*` option declarations and computed defaults |
| `modules/home.nix` | home-manager base (fonts, nix.conf, darwin helpers) |
| `modules/features/` | cross-platform home-manager modules (shell, editor, git, packages, theme, ai) |
| `modules/desktop/` | desktop-environment modules (niri, aerospace) |
| `modules/nixos/` | NixOS system modules (base, desktop, networking, ssh, etc.) |
| `modules/hosts/` | per-host hardware config only (filesystems, kernel modules) |
| `modules/flake/` | flake-parts modules (configurations, checks, formatter) |
| `modules/lib/` | helper libraries |
| `modules/features/ai/` | AI tooling: assistant context, brain (transcript digest), maki, providers, sdlc, skills |
| `modules/features/tv/` | Television repository and worktree cables |
| `modules/features/photobucket/` | feh-based keyboard photo triage tool + its Python helper |
| `modules/features/cloudflare/` | Cloudflare Tunnel DNS/Access reconciler (Python helper) + manual `cloudflare-sync` CLI |
| `tests/` | Python unit tests for the sdlc, maki, brain, photobucket, and cloudflare tools, plus `tests/*.sh` shell checks (all run via flake checks) |

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
- **Gate on `dotfiles.*`, not `enable` flags**: every module is imported on
  every host. Gate behavior on `config.dotfiles.*` values (e.g.
  `lib.mkIf isLinux`, `lib.mkIf config.dotfiles.graphical`). `mkEnableOption`
  is reserved for genuinely optional subfeatures that default to off
  (`dotfiles.webProxy.enable`, `dotfiles.calibre.enable`); do not add a
  top-level `enable` for a whole module.
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
nix eval .#checks.x86_64-linux.eval-nixos-smoresbook --apply 'x: true'
```

The Python tools under `modules/features/ai/` have unit tests in `tests/`,
run by the `checks` flake module (`python -m unittest discover -s tests`).
Run them after touching `modules/features/ai/sdlc/`, maki session search, or `modules/features/ai/brain/`.

Script checks run each `tests/<name>.sh` against tools and files from a
generated home, as the `<name>` flake check (`scriptChecks` in
`modules/flake/checks.nix`): `git-work-routing` (work vs personal identity by
remote URL), `ssh-agent-keys` (agent key loading), `ssh-allowed-signers`
(signature verification), `worktrees-branch-template` (branch naming from
per-repo templates), `repos-list-links` (listing through linked org dirs),
`work-repo-links` (the work host's flat-folder links) and `zsh-config`
(generated zsh startup files parse; only on a system with a zsh home). Run
them after touching shell, git or ssh settings or
`modules/lib/repo-workflow.nix`:

```sh
nix build .#checks.aarch64-darwin.{git-work-routing,ssh-agent-keys,ssh-allowed-signers,worktrees-branch-template,repos-list-links,work-repo-links,zsh-config}
```

For home-manager changes, run `home-manager switch --flake .#smores@<host>`
(e.g. `.#smores@smoresbook` on this machine) to verify activation succeeds
(not just evaluation).

## Repo conventions

- Wallpapers are LFS-tracked (`.gitattributes`).
