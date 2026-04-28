# Nix Config

NixOS system configs and home-manager user configs for all my machines.
Follows the [dendritic pattern](https://github.com/mightyiam/dendritic) using [flake-parts](https://github.com/hercules-ci/flake-parts) and [import-tree](https://github.com/vic/import-tree).

## Hosts

| Host | System | Desktop | Config type |
|---|---|---|---|
| `smohr` | macOS (aarch64) | Paneru / Aerospace | home-manager |
| `smoresbook` | NixOS | Niri + Noctalia | NixOS + home-manager |
| `smorestux` | NixOS | Niri + Noctalia | NixOS + home-manager |
| `campfire` | NixOS | headless | NixOS + home-manager |
| `smortress` | Linux | Pop/GNOME | home-manager |
| `smoresnet` | Linux | headless | home-manager |

## Usage

```bash
# Home-manager
home-manager switch --flake ~/.config/nix#smores@<hostname>   # Linux
home-manager switch --flake ~/.config/nix#smohr               # macOS

# NixOS
sudo nixos-rebuild switch --flake ~/.config/nix#<hostname> --upgrade

# Format all nix files
nix fmt
```

## SSH Access

SSH between machines uses [Tailscale SSH](https://tailscale.com/kb/1193/tailscale-ssh/).
Authentication is identity-based through the tailnet — no SSH keys needed for
interactive sessions. MagicDNS provides hostnames (`ssh smores@campfire`).

### Tailscale ACLs

Configure in the [Tailscale admin console](https://login.tailscale.com/admin/acls).
The SSH ACL section should allow all tailnet members to SSH as any non-root user:

```json
{
  "ssh": [
    {
      "action": "accept",
      "src": ["autogroup:member"],
      "dst": ["autogroup:self"],
      "users": ["autogroup:nonroot", "root"]
    }
  ]
}
```

### Nix remote builds

Remote builds use `campfire` as a build host over Tailscale SSH:

```bash
nix build --builders 'ssh://smores@campfire x86_64-linux'
```

The `smores` user is in `trusted-users` on campfire (configured via `exposeSsh = true`).

## New machine setup

```bash
nix-shell -p git gh home-manager helix
gh auth login
gh repo clone smores56/nix-config ~/.config/nix
home-manager switch --flake ~/.config/nix#$USER@$(hostname)

# NixOS only:
sudo nixos-generate-config
cp /etc/nixos/hardware-configuration.nix ~/.config/nix/modules/hosts/$(hostname).nix
sudo nixos-rebuild switch --flake ~/.config/nix#$(hostname) --upgrade
```

### Joining the tailnet

**Client (any machine):**

```bash
sudo tailscale up    # opens browser for auth
```

**Server (NixOS host accepting SSH):**

Set `exposeSsh = true` in the host's entry in `modules/flake/configurations.nix`,
then rebuild. This enables Tailscale SSH and marks the user as a trusted nix builder.
Run `sudo tailscale up` on first boot to authenticate.

**Non-NixOS server:**

```bash
tailscale up
tailscale set --ssh
```

## Optional setup

### Fingerprint authentication (smoresbook)

After rebuilding with `fingerprint = true`, enroll your fingerprint:

```bash
sudo fprintd-enroll smores
```

Follow the prompts to swipe your finger. Once enrolled, the Noctalia lock screen will accept fingerprint or password.

## Code quality

```bash
# Format all nix files
nix fmt

# Lint with statix
nix run nixpkgs#statix -- check .

# Auto-fix statix warnings
nix run nixpkgs#statix -- fix .
```

## Architecture

`flake.nix` is a thin shell — inputs + `flake-parts.lib.mkFlake` delegating to `modules/flake/`. All module discovery is handled by `import-tree`, which recursively loads every `.nix` file in a directory.

Per-host properties (`displayManager`, `helixTheme`, etc.) are set inline in `modules/flake/configurations.nix` via `config.dotfiles.*`. Options are validated by `modules/options.nix` using `lib.mkOption` with typed enums.

Modules are organized by feature, not by system type. Each module gates itself with `lib.mkIf` on `config.dotfiles.*`, so everything is loaded unconditionally and activates based on the host's configuration.

### Module structure

```
modules/
  flake/             — flake-parts plumbing (configurations, formatter)
  options.nix        — unified dotfiles options (displayManager, polarity, etc.)
  home/              — home-manager base (stateVersion, fonts, cursor, xdg)
  features/          — CLI tools and configs (all hosts)
    shell/           — fish config, abbreviations, functions
    editor/          — helix + LSPs
    terminal/        — wezterm, kitty, alacritty, ghostty (config-only via package = pkgs.nil)
    git, theme, packages, multiplexer, file-manager
  desktop/           — display-manager-specific HM modules (mkIf-gated)
    niri, aerospace, paneru, pop-os, linux-apps
  nixos/             — NixOS system modules (mkIf-gated where needed)
    base, niri, sound, ssh, networking, bluetooth, etc.
  hosts/             — per-host hardware configs (referenced explicitly)
```
