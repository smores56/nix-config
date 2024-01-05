{ pkgs, specialArgs, ... }:
let
  isLinux = pkgs.stdenv.isLinux;
  username = specialArgs.username or "smores";
  homeDirectory = specialArgs.homeDirectory or "/home/${username}";

  wallpaper = specialArgs.wallpaper or ../wallpapers/angled-waves.png;
  stylixBase =
    if builtins.hasAttr "colorscheme" specialArgs then {
      base16Scheme = "${pkgs.base16-schemes}/share/themes/${specialArgs.colorscheme}.yaml";
    } else { };

  cascadiaCodeFont = {
    name = "CaskaydiaCove Nerd Font Mono";
    package = pkgs.cascadia-code;
  };
  machineType = specialArgs.machineType or null;
  machineConfig =
    if machineType == "server" then
      { highResolution = false; hasDisplay = false; }
    else if machineType == "desktop" then
      { highResolution = true; hasDisplay = true; }
    else if machineType == "laptop" then
      { highResolution = false; hasDisplay = true; }
    else abort "Invalid `machineType`, please provide server, desktop, or laptop";
in
with machineConfig; {
  home = {
    stateVersion = "23.11";
    packages = [ pkgs.home-manager ];
    username = username;
    homeDirectory = homeDirectory;
  };

  targets.genericLinux.enable = isLinux;
  xdg =
    if isLinux then {
      enable = true;
      mime.enable = true;
      systemDirs.data = [
        "${homeDirectory}/.nix-profile/share/applications"
      ];
    } else { };

  stylix = stylixBase // {
    image = wallpaper;
    polarity = specialArgs.polarity or "either";
    autoEnable = true;
    opacity.terminal = 0.9;
    fonts = {
      sizes = {
        desktop = 12;
        terminal = if highResolution then 14 else 14;
      };
      monospace = cascadiaCodeFont;
      sansSerif = cascadiaCodeFont;
      emoji = cascadiaCodeFont;
    };
  };

  imports = [ ./terminal ] ++ (if hasDisplay then [ ./gui ./hyprland ] else [ ]);
}
