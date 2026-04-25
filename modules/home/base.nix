{
  config,
  pkgs,
  lib,
  ...
}:
let
  inherit (pkgs.stdenv) isLinux;
in
{
  home = {
    stateVersion = "26.05";
    packages = [
      pkgs.home-manager
      pkgs.nerd-fonts.caskaydia-cove
      pkgs.open-sans
    ];

    activation.checkAppManagementPermission = lib.mkIf pkgs.stdenv.isDarwin (
      lib.mkForce {
        before = [ ];
        after = [ ];
        data = "";
      }
    );

    pointerCursor = lib.mkIf (isLinux && config.dotfiles.displayManager != null) {
      package = pkgs.bibata-cursors;
      name = "Bibata-Modern-Classic";
      size = 16;
    };
  };

  targets.genericLinux.enable = isLinux;
  xdg = lib.mkIf isLinux {
    enable = true;
    mime.enable = true;
    systemDirs.data = [
      "${config.home.homeDirectory}/.nix-profile/share/applications"
    ];
  };
}
