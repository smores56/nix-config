{ pkgs, specialArgs, ... }:
let
  isLinux = pkgs.stdenv.isLinux;
  username = specialArgs.username or "smores";
  homeDirectory = specialArgs.homeDirectory or "/home/${username}";

  largeScreen = (specialArgs.screenSize or "small") == "large";
  wallpaper = specialArgs.wallpaper or ../wallpapers/angled-waves.png;
  stylixBase = if builtins.hasAttr "colorscheme" specialArgs then {
    base16Scheme = "${pkgs.base16-schemes}/share/themes/${specialArgs.colorscheme}.yaml";
  } else {};

  cascadiaCodeFont = {
    name = "CaskaydiaCove Nerd Font Mono";
    package = pkgs.cascadia-code;
  };
in
{
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
        terminal = if largeScreen then 12 else 14;
      };
      monospace = cascadiaCodeFont;
      sansSerif = cascadiaCodeFont;
      emoji = cascadiaCodeFont;
    };
  };

  imports = [ ./terminal ];
}
