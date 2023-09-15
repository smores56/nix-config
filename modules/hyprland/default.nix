{ config, pkgs, hyprland, ... }: {
  wayland.windowManager.hyprland = {
    enable = true;
    extraConfig = (import ./config.nix {
      inherit (config);
    });
  };

  imports = [
    ./waybar
    ./swaylock.nix
  ];

  home.packages = with pkgs; [
    hyprpaper
    wofi
  ];

  home.file.".config/hypr/hyprpaper.conf".text = ''
    preload = ${/. + ../../wallpapers/rocket-launch.png}
    wallpaper = ,${/. + ../../wallpapers/rocket-launch.png}
    ipc = off
  '';
}
