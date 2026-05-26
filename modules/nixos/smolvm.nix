# SmolVM microVM runtime — system-level packages for stable sudoers paths.
# SmolVM's sudoers config pins exact binary paths; NixOS system profile
# provides stable paths at /run/current-system/sw/bin/.
# Run `scripts/setup-smolvm.sh` (in the camp repo) after building to configure sudoers.
{ pkgs, ... }:
{
  environment.systemPackages = [
    pkgs.firecracker
    pkgs.nftables
  ];
}
