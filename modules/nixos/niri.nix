{
  config,
  lib,
  ...
}:
{
  config = lib.mkIf (config.dotfiles.displayManager == "niri") {
    programs.niri.enable = true;

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
      substituters = [ "https://noctalia.cachix.org" ];
      trusted-public-keys = [ "noctalia.cachix.org-1:pCOR47nnMEo5thcxNDtzWpOxNFQsBRglJzxWPp3dkU4=" ];
    };
  };
}
