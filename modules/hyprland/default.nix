{ pkgs, wallpaper, ... }:
{
  stylix.targets.hyprland.enable = true;

  wayland.windowManager.hyprland = {
    enable = true;
    extraConfig = (import ./config.nix { pkgs = pkgs; });
  };

  imports = [
    ./waybar.nix
    ./swaylock.nix
    ./swayidle.nix
  ];

  home.packages = with pkgs; [
    hyprpaper
    grimblast
    brightnessctl
  ];

  programs.fuzzel.enable = true;
  stylix.targets.fuzzel.enable = true;

  home.file.".config/hypr/hyprpaper.conf".text = ''
    preload = ${wallpaper}
    wallpaper = ,${wallpaper}
    ipc = off
  '';
}
