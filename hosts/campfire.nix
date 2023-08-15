{ pkgs, ... }: {
  home.username = "smores";
  home.homeDirectory = "/home/smores";
  home.stateVersion = "23.11";

  xdg.enable = true;
  programs.home-manager.enable = true;

  imports = [
    ../modules/shell
    ../modules/hyprland
    ../modules/gui
  ];
}
