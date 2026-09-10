{
  config,
  lib,
  pkgs,
  ...
}:
{
  config = lib.mkIf (config.dotfiles.displayManager == "niri") {
    programs.niri.enable = true;
    programs.niri.package = pkgs.niri-unstable;
    environment.systemPackages = [ pkgs.xwayland-satellite-unstable ];

    # portal-gnome (>=47) needs Nautilus for file pickers; route FileChooser to
    # the GTK portal instead since we don't ship Nautilus. Overrides the
    # niri-portals.conf `default=gnome;gtk;` shipped by the niri package.
    xdg.portal = {
      enable = true;
      config.niri = {
        default = [
          "gnome"
          "gtk"
        ];
        "org.freedesktop.impl.portal.FileChooser" = "gtk";
        "org.freedesktop.impl.portal.Access" = "gtk";
        "org.freedesktop.impl.portal.Notification" = "gtk";
      };
      extraPortals = [
        pkgs.xdg-desktop-portal-gnome
        pkgs.xdg-desktop-portal-gtk
      ];
    };

    services = {
      libinput.enable = true;
      upower.enable = true;
      power-profiles-daemon.enable = true;
      greetd = {
        enable = true;
        settings = {
          default_session = {
            command = "niri-session";
            user = config.dotfiles.username;
          };
          initial_session = {
            command = "niri-session";
            user = config.dotfiles.username;
          };
        };
      };
    };

    nix.settings = {
      substituters = [
        "https://niri.cachix.org"
        "https://noctalia.cachix.org"
      ];
      trusted-public-keys = [
        "niri.cachix.org-1:Wv0OmO7PsuocRKzfDoJ3mulSl7Z6oezYhGhR+3W2964="
        "noctalia.cachix.org-1:pCOR47nnMEo5thcxNDtzWpOxNFQsBRglJzxWPp3dkU4="
      ];
    };
  };
}
