{ pkgs, specialArgs, ... }:
let
  isLinux = pkgs.stdenv.isLinux;
  username = specialArgs.username or "smores";
  homeDirectory = specialArgs.homeDirectory or "/home/${username}";

  stylixBase =
    if builtins.hasAttr "wallpaper" specialArgs then {
      image = specialArgs.wallpaper;
    } else {
      base16Scheme = "${pkgs.base16-schemes}/share/themes/rose-pine.yaml";
    };

  machineType = specialArgs.machineType or null;
  machineConfig =
    if machineType == "server" then
      { largeScreen = false; headless = true; }
    else if machineType == "desktop" then
      { largeScreen = true; headless = false; }
    else if machineType == "laptop" then
      { largeScreen = false; headless = false; }
    else abort "Invalid `machineType`, please specify server, desktop, or laptop";
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
    } else null;

  stylix = stylixBase // {
    polarity = specialArgs.polarity or "either";
    autoEnable = true;
    opacity.terminal = 0.9;
    fonts.sizes.terminal = if largeScreen then 12 else 14;
    fonts.monospace = {
      name = "CaskaydiaCove Nerd Font Mono";
      package = pkgs.cascadia-code;
    };
  };

  imports = [ ./terminal ] ++ (if headless then [ ] else [ ./hyprland ./gui ]);
}
