Nix Config
==========

Configuration for my Nix home/programs and NixOS programs/services.

## Setup

For NixOS, run the following:

```bash
export HOSTNAME=<hostname> # set -xg HOSTNAME <hostname> on fish shell

nix-shell -p git gh home-manager
ssh-keygen -t ed25519 -b 4096 -C $HOSTNAME
gh auth login
git clone git@github.com:smores56/nix-config.git
home-manager switch --flake ~/.config/nix
sudo ln -sf ~/.config/nix/hosts/$HOSTNAME/nixos.nix /etc/nixos/configuration.nix
sudo nixos-generate-config
sudo nixos-rebuild switch --upgrade
```

### Theming to consider

- Modus-Operandi-Tinted
