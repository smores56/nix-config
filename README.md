Nix Config
==========

Configuration for my Nix home/programs and NixOS programs/services.

## Setup

For NixOS, run the following:

```bash
export HOSTNAME=<hostname> # set -xg HOSTNAME <hostname> on fish shell

nix-shell -p git gh home-manager helix
ssh-keygen -t ed25519 -b 4096 -C $HOSTNAME
gh auth login
gh repo clone smores56/nix-config ~/.config/nix
home-manager switch --flake ~/.config/nix#$USER@$HOSTNAME

sudo nixos-generate-config
cp /etc/nixos/hardware-configuration.nix ~/.config/nix/hardware-configuration/$HOSTNAME.nix
sudo ln -sf ~/.config/nix/flake.nix /etc/nixos/flake.nix
sudo nixos-rebuild switch --flake ~/.config/nix#$HOSTNAME --upgrade
```
