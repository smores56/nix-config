# Core CLI toolset, imported by every host.
{
  home = [
    ../features/ai/providers.nix
    ../features/packages.nix
    ../features/tv/default.nix
    ../features/file-manager.nix
  ];
  nixos = [
    ../nixos/base.nix
    ../nixos/networking.nix
    ../nixos/ssh.nix
  ];
}
