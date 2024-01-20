{ pkgs, specialArgs, isLinux, displayManager, ... }:
let
  username = specialArgs.username or "smores";
  homeDirectory = specialArgs.homeDirectory or "/home/${username}";

  wallpaper = specialArgs.wallpaper or ../wallpapers/angled-waves.png;
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

  home.file.".xinitrc".text = ''
    ${pkgs.xorg.xmodmap}/bin/xmodmap -e "keycode 94 = Shift_L"
  '';

  targets.genericLinux.enable = isLinux;
  xdg =
    if isLinux then {
      enable = true;
      mime.enable = true;
      systemDirs.data =
        if displayManager == "hyprland" then [
          "${homeDirectory}/.nix-profile/share/applications"
        ] else [ ];
    } else { };

  stylix = stylixBase // {
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
        terminal = if displayManager == "hyprland" then 12 else 11;
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

    targets.gnome.enable = displayManager == "pop-os";
  };

  imports = [ ./terminal ] ++ (if displayManager == "hyprland" then [ ./gui ./hyprland ] else [ ]);
}
