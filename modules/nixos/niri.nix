{
  config,
  lib,
  pkgs,
  ...
}:
{
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

  # greetd is not enabled here: a greeter is a host concern (e.g.
  # modules/hosts/smorespro/greeter.nix), and niri must start from the login
  # session, never from greetd's default_session.
  services = {
    libinput.enable = true;
    upower.enable = true;
    power-profiles-daemon.enable = true;
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
}
