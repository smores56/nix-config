{ pkgs, wallpaper, ... }: {
  wayland.windowManager.hyprland = {
    enable = true;
    extraConfig = (import ./config.nix {});
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

  home.file.".config/hypr/hyprpaper.conf".text = ''
    preload = ${wallpaper}
    wallpaper = ,${wallpaper}
    ipc = off
  '';
}
