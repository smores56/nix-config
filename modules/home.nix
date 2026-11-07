{
  config,
  pkgs,
  lib,
  ...
}:
let
  inherit (pkgs.stdenv.hostPlatform) isLinux;
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  cfg = config.user;
  darwinFontsEnv = pkgs.buildEnv {
    name = "home-manager-fonts";
    paths = [ cfg.fontPackage ];
    pathsToLink = [ "/share/fonts" ];
  };
  darwinFonts = "${darwinFontsEnv}/share/fonts";
  darwinFontsInstallDir = "${config.home.homeDirectory}/Library/Fonts/HomeManager";

  # Home Manager's Darwin collector passes `nix.gc.options` as one argv
  # element, so build the list once and override ProgramArguments with it.
  gcOptions = [
    "--delete-older-than"
    "30d"
  ];
  nixPackage =
    if config.nix.enable && config.nix.package != null then config.nix.package else pkgs.nix;
in
{
  home = {
    stateVersion = "26.05";
    packages = [
      pkgs.home-manager
      config.user.fontPackage
    ];
    file.".config/home-manager" = {
      source = config.lib.file.mkOutOfStoreSymlink "${cfg.reposRoot}/github.com/smores56/nix-config";
      force = true;
    };
    file.".config/nix/nix.conf".text = ''
      warn-dirty = false
      experimental-features = nix-command flakes
    '';
    file."Library/Fonts/.home-manager-fonts-version" = lib.mkIf isDarwin (
      lib.mkForce {
        text = "${darwinFontsEnv}\nsync-version=2";
        onChange = ''
          run mkdir -p ${lib.escapeShellArg darwinFontsInstallDir}
          run /bin/chmod -R u+w ${lib.escapeShellArg darwinFontsInstallDir} || true
          run ${pkgs.rsync}/bin/rsync $VERBOSE_ARG -acL --chmod=u+w --delete \
            ${lib.escapeShellArgs [
              "${darwinFonts}/"
              "${darwinFontsInstallDir}/"
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

  # NixOS collects through the root timer (modules/nixos/base.nix): a user
  # service cannot reach the store when only root is trusted. A non-NixOS host
  # has no system plane, so its user agent is the only collector there.
  nix.gc = lib.mkIf (!config.machine.nixos) {
    automatic = true;
    dates = "weekly";
    options = lib.concatStringsSep " " gcOptions;
  };

  launchd.agents.nix-gc.config.ProgramArguments = lib.mkIf isDarwin (
    lib.mkForce ([ "${nixPackage}/bin/nix-collect-garbage" ] ++ gcOptions)
  );

  # The root collector does not know the home-manager profile under
  # ~/.local/state/nix/profiles, so expire its old generations as the user; the
  # next system run frees the store paths they held.
  services.home-manager.autoExpire = lib.mkIf (isLinux && config.machine.nixos) {
    enable = true;
    frequency = "weekly";
    timestamp = "-30 days";
  };

  targets.genericLinux.enable = isLinux && !config.machine.nixos;
  xdg = lib.mkIf isLinux {
    enable = true;
    mime.enable = true;
    systemDirs.data = [
      "${config.home.homeDirectory}/.nix-profile/share/applications"
    ];
  };
}
