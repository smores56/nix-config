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

    services = {
      libinput.enable = true;
      upower.enable = true;
      power-profiles-daemon.enable = true;
      greetd = {
        enable = true;
        settings.default_session = {
          command = "niri-session";
          user = "smores";
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
