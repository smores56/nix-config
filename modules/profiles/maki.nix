# Maki in the agent VM on the personal Linux hosts (modules/nixos/agent-vm.nix).
{
  home = [
    ../features/ai/maki/default.nix
    ../features/agent-vm/linux.nix
  ];
  nixos = [ ../nixos/agent-vm.nix ];
}
