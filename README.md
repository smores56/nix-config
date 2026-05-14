# Nix Config

Personal NixOS and Home Manager configs for my machines. The flake follows the
[dendritic pattern](https://github.com/mightyiam/dendritic) with
[flake-parts](https://github.com/hercules-ci/flake-parts) and
[import-tree](https://github.com/vic/import-tree).

## Hosts

| Host | System | Desktop | Config type |
|---|---|---|---|
| `smoreswork` | macOS aarch64 | Aerospace | Home Manager |
| `smoresbook` | NixOS | Niri + Noctalia | NixOS + Home Manager |
| `smorestux` | NixOS | Niri + Noctalia | NixOS + Home Manager |
| `campfire` | NixOS | headless | NixOS + Home Manager |
| `smortress` | NixOS | Niri + Noctalia | NixOS + Home Manager |
| `smoresnet` | Linux | headless | Home Manager |

## Commands

```bash
# Home Manager, through ~/.config/home-manager
home-manager switch --no-write-lock-file

# NixOS
sudo nixos-rebuild switch --flake ~/dev/github.com/smores56/nix-config --upgrade

# Format and check
nix fmt
nix fmt -- --check .
nix flake check --no-write-lock-file
nix run nixpkgs#statix -- check .
```

## Bootstrap

On a fresh machine with Nix installed, from Bash, Zsh, or Fish:

```sh
curl -fsSL bootstrap.sammohr.dev | bash
```

Override auto-detected username or hostname:

```sh
curl -fsSL bootstrap.sammohr.dev | env BOOTSTRAP_USER=smohr BOOTSTRAP_HOST=smoreswork bash
```

The bootstrap GitHub account defaults to `smores56`. Override it only when
intentionally registering keys with a different account:

```sh
curl -fsSL bootstrap.sammohr.dev | env BOOTSTRAP_GITHUB_USER=smores56 bash
```

The script clones the repo, symlinks `~/.config/home-manager`, runs Home Manager,
sets up an SSH key, authenticates GitHub with device flow, switches the repo
remote to SSH, and runs the NixOS rebuild when the current hostname has a
`nixosConfiguration`.

## NixOS Notes

Tailscale is enabled on NixOS hosts. Join each machine to the tailnet once after
first boot:

```bash
sudo tailscale up
```

Hosts with `exposeSsh = true` enable Tailscale SSH and mark the configured user
as a trusted Nix builder. Join those hosts with Tailscale SSH enabled:

```bash
sudo tailscale up --ssh
```

Rebuilds also run the official `tailscale set --ssh` path for exposed SSH hosts,
so Tailscale SSH stays advertised after the one-time join.

After switching the system, verify Tailscale is running:

```bash
systemctl status tailscaled
tailscale status --json --peers=false
```

Remote builds can use `campfire` over Tailscale SSH:

```bash
nix build --builders 'ssh://smores@campfire x86_64-linux'
```

### Fingerprint Authentication

`smoresbook` enables the Goodix fingerprint override. Enroll after rebuilding:

```bash
sudo fprintd-enroll smores
```

## Architecture

`flake.nix` only declares inputs and delegates to `modules/flake/`. `import-tree`
loads feature and desktop modules recursively, while host hardware modules are
referenced explicitly from `modules/flake/configurations.nix`.

Shared `dotfiles.*` options live in `modules/options.nix`. Most modules are
loaded for every Home Manager or NixOS config and activate with `lib.mkIf` based
on those options.

```
modules/
  flake/       flake-parts outputs, formatter, checks
  options.nix  shared dotfiles options and defaults
  home.nix     base Home Manager settings
  features/    shell, editor, git, theme, packages, repos, zellij
  desktop/     Niri, Noctalia, Aerospace, Paneru, Linux desktop apps
  nixos/       system modules for bootstrapping NixOS hosts
  hosts/       per-host hardware configuration
  lib/         small shared Nix helpers
tests/         repo-local tests used by flake checks
```
