{ config, pkgs, hyprland, ... }: {
  wayland.windowManager.hyprland = {
    enable = true;
    extraConfig = (import ./config.nix {
      inherit (config);
    });
  };

  imports = [
    ./waybar
  ];

  home.packages = with pkgs; [
    hyprpaper
    wofi
  ];

  home.file.".config/hypr/hyprpaper.conf".text = ''
    preload = ${/. + ../../misc/wallpaper.jpg}
    wallpaper = ,${/. + ../../misc/wallpaper.jpg}
    ipc = off
  '';
}
