{
  config,
  pkgs,
  lib,
  ...
}:
let
  inherit (pkgs.stdenv) isLinux;
  cfg = config.dotfiles;
in
{
  home = {
    stateVersion = "26.05";
    packages = [
      pkgs.home-manager
      config.dotfiles.fontPackage
    ];

    activation.checkAppManagementPermission = lib.mkIf pkgs.stdenv.isDarwin (
      lib.mkForce {
        before = [ ];
        after = [ ];
        data = "";
      }
    );
  };

  targets.genericLinux.enable = isLinux && !cfg.nixos;
  xdg = lib.mkIf isLinux {
    enable = true;
    mime.enable = true;
    systemDirs.data = [
      "${config.home.homeDirectory}/.nix-profile/share/applications"
    ];
  };
}
