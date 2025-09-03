{ pkgs, ... }:
{
  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs; [
    libz
    libgcc
    ncurses
  ];

  imports = [
    ./i18n.nix
    ./disks.nix
    ./security.nix
    ./bluetooth.nix
    ./networking.nix
  ];
}
