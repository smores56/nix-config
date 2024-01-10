{ pkgs, specialArgs, isLinux, ... }:
let
  username = specialArgs.username or "smores";
  homeDirectory = specialArgs.homeDirectory or "/home/${username}";

  wallpaper = specialArgs.wallpaper or ../wallpapers/angled-waves.png;
  stylixBase =
    if builtins.hasAttr "colorscheme" specialArgs then {
      base16Scheme = "${pkgs.base16-schemes}/share/themes/${specialArgs.colorscheme}.yaml";
    } else { };

  machineType = specialArgs.machineType or null;
  machineConfig =
    if machineType == "server" then
      { highResolution = false; hasDisplay = false; }
    else if machineType == "desktop" then
      { highResolution = true; hasDisplay = isLinux; }
    else if machineType == "laptop" then
      { highResolution = false; hasDisplay = isLinux; }
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
    opacity.terminal = if isLinux then 0.9 else 1.0;

    cursor = {
      package = pkgs.bibata-cursors;
      name = "Bibata-Modern-Classic";
      size = 24;
    };

    fonts = {
      sizes = {
        desktop = if highResolution then 14 else 12;
        terminal = 14;
      };
      monospace = {
        name = "JetBrainsMono Nerd Font Mono";
        package = pkgs.cascadia-code;
      };
      sansSerif = {
        name = "Ubuntu Nerd Font";
        package = pkgs.nerdfonts;
      };
    };
  };

  imports = [ ./terminal ] ++ (if machineConfig.hasDisplay then [ ./gui ./hyprland ] else [ ]);
}
