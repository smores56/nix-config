{
  config,
  pkgs,
  lib,
  ...
}:
let
  inherit (pkgs.stdenv) isLinux;
  isDarwin = pkgs.stdenv.isDarwin;
  cfg = config.dotfiles;
  darwinFontsEnv = pkgs.buildEnv {
    name = "home-manager-fonts";
    paths = [ cfg.fontPackage ];
    pathsToLink = [ "/share/fonts" ];
  };
  darwinFonts = "${darwinFontsEnv}/share/fonts";
  darwinFontsInstallDir = "${config.home.homeDirectory}/Library/Fonts/HomeManager";
in
{
  home = {
    stateVersion = "26.05";
    packages = [
      pkgs.home-manager
      config.dotfiles.fontPackage
    ];
    file.".config/home-manager" = {
      source = config.lib.file.mkOutOfStoreSymlink "${cfg.codeRoot}/github.com/smores56/nix-config";
      force = true;
    };
    file.".config/nix/nix.conf".text = ''
      warn-dirty = false
      accept-flake-config = true
      experimental-features = nix-command flakes
    '';
    file."Library/Fonts/.home-manager-fonts-version" = lib.mkIf isDarwin (
      lib.mkForce {
        text = "${darwinFontsEnv}";
        onChange = ''
          run mkdir -p ${lib.escapeShellArg darwinFontsInstallDir}
          run /usr/bin/rsync $VERBOSE_ARG -acL --chmod=u+w --delete \
            ${lib.escapeShellArgs [
              "${darwinFonts}/"
              darwinFontsInstallDir
            ]}
        '';
      }
    );

    activation.checkAppManagementPermission = lib.mkIf isDarwin (
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
