{ pkgs, ... }:
{
  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs; [
    libz
    libgcc
    # libstdcxx5
    ncurses
  ];

  imports = [
    ./i18n.nix
    ./disks.nix
    ./security.nix
    ./bluetooth.nix
    ./networking.nix
    ./rfkill-unblock.nix
  ];
}
