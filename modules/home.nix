{ pkgs, ... }: {
  home.username = "smores";
  home.homeDirectory = "/home/smores";
  home.stateVersion = "23.11";

  xdg.enable = true; 
  programs.home-manager.enable = true;

  home.sessionVariables = {
    GUM_CHOOSE_CURSOR_FOREGROUND = 3;
    # LS_COLORS (cat ~/.config/fish/ls-colors.txt)
  };

  imports = [
    ./gui/gui.nix
    ./fish/fish.nix
    ./shell/shell.nix
  ];

  home.packages = [ pkgs.tailscale ];

  systemd.user.startServices = "sd-switch";
}
