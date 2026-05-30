{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.dotfiles.paseo;
  enabled = cfg.enable && pkgs.stdenv.isLinux;
  paseoPkg = inputs.paseo.packages.${pkgs.stdenv.hostPlatform.system}.default;
  homeDir = config.home.homeDirectory;

  scriptPath =
    "${homeDir}/.nix-profile/bin:${homeDir}/.local/state/nix/profile/bin:"
    + "/etc/profiles/per-user/${config.dotfiles.username}/bin:"
    + "/run/current-system/sw/bin:/run/wrappers/bin:/nix/var/nix/profiles/default/bin";
in
{
  config = lib.mkIf enabled {
    home.packages = [ paseoPkg ];

    systemd.user.services.paseo = {
      Unit = {
        Description = "Paseo daemon for AI coding agents";
        After = [ "network.target" ];
      };
      Service = {
        Type = "simple";
        ExecStart = "${paseoPkg}/bin/paseo-server --no-relay";
        Restart = "on-failure";
        RestartSec = 5;
        Environment = [
          "NODE_ENV=production"
          "PASEO_HOME=${homeDir}/.paseo"
          "PASEO_LISTEN=0.0.0.0:6767"
          "PASEO_HOSTNAMES=true"
          "PATH=${scriptPath}"
        ];
      };
      Install = {
        WantedBy = [ "default.target" ];
      };
    };
  };
}
