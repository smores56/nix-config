{ pkgs, wallpaper, ... }: {
  wayland.windowManager.hyprland = {
    enable = true;
    extraConfig = (import ./config.nix {});
  };

  imports = [
    ./waybar
    ./swaylock.nix
    ./swayidle.nix
  ];

  home.packages = with pkgs; [
    hyprpaper
    wofi
    grimblast
  ];

  home.file.".config/hypr/hyprpaper.conf".text = ''
    preload = ${wallpaper}
    wallpaper = ,${wallpaper}
    ipc = off
  '';
}
