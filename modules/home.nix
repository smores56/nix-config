{
  pkgs,
  specialArgs,
  isLinux,
  displayManager,
  ...
}:
let
  username = specialArgs.username or "smores";
  homeDirectory = specialArgs.homeDirectory or "/home/${username}";
in
{
  home = {
    stateVersion = "26.05";
    packages = [
      pkgs.home-manager
      pkgs.nerd-fonts.caskaydia-cove
      pkgs.open-sans
    ];
    username = username;
    homeDirectory = homeDirectory;

    activation.checkAppManagementPermission = pkgs.lib.mkIf pkgs.stdenv.isDarwin (
      pkgs.lib.mkForce {
        before = [ ];
        after = [ ];
        data = "";
      }
    );

    pointerCursor = pkgs.lib.mkIf (isLinux && displayManager != null) {
      package = pkgs.bibata-cursors;
      name = "Bibata-Modern-Classic";
      size = 16;
    };
  };

  targets.genericLinux.enable = isLinux;
  xdg =
    if isLinux then
      {
        enable = true;
        mime.enable = true;
        systemDirs.data = [
          "${homeDirectory}/.nix-profile/share/applications"
        ];
      }
    else
      { };

  imports = [ ./tools ] ++ (if displayManager != null then [ ./gui ] else [ ]);
}
