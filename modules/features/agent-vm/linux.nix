# The Linux agent boundary (sdlc #386): `agent-sandbox maki` runs maki in the microvm guest that
# modules/nixos/agent-vm.nix declares. Plain `maki` on the host stays the deliberate opt-out.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  agentVm = import ../../lib/agent-vm.nix { inherit pkgs lib; };
in
{
  config = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
    home.packages = [ (agentVm.launcher config.home.username) ];
  };
}
