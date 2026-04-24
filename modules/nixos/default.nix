{ pkgs, ... }:
{
  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs; [
    libz
    libgcc
    ncurses
  ];

  imports = [
    ./options.nix
    ./i18n.nix
    ./disks.nix
    ./security.nix
    ./bluetooth.nix
    ./networking.nix
  ];
}
