{ pkgs, specialArgs, isLinux, displayManager, ... }:
let
  username = specialArgs.username or "smores";
  homeDirectory = specialArgs.homeDirectory or "/home/${username}";

  wallpaper = specialArgs.wallpaper or ../wallpapers/angled-waves.png;
  terminalFontSize = specialArgs.terminalFontSize or 12;
  stylixBase =
    if builtins.hasAttr "colorscheme" specialArgs then {
      base16Scheme = "${pkgs.base16-schemes}/share/themes/${specialArgs.colorscheme}.yaml";
    } else { };
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
      systemDirs.data = ["${homeDirectory}/.nix-profile/share/applications"];
    } else { };

  stylix = stylixBase // {
    enable = displayManager != null;
    image = wallpaper;
    autoEnable = false;
    polarity = specialArgs.polarity or "either";
    opacity.terminal = if isLinux then 0.9 else 1.0;

    cursor = {
      package = pkgs.bibata-cursors;
      name = "Bibata-Modern-Classic";
      size = 16;
    };

    fonts = {
      sizes = {
        desktop = 14;
        terminal = terminalFontSize;
      };
      monospace = {
        name = "CaskaydiaCove NF SemiBold";
        package = pkgs.nerd-fonts.caskaydia-cove;
      };
    };

    targets.gnome.enable = displayManager == "pop-os";
  };

  imports = [ ./terminal ] ++ (if displayManager == "pop-os" then [ ./gui ] else [ ]);
}
