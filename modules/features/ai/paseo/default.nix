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

  stripPassword = pkgs.writeShellScript "paseo-strip-password" ''
    config_file="${homeDir}/.paseo/config.json"
    [ -f "$config_file" ] || exit 0
    ${pkgs.jq}/bin/jq 'del(.daemon.auth.password)' "$config_file" > "$config_file.tmp" && mv "$config_file.tmp" "$config_file"
  '';
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
        ExecStart = "${paseoPkg}/bin/paseo-server";
        ExecStartPre = "${stripPassword}";
        Restart = "on-failure";
        RestartSec = 5;
        Environment = [
          "NODE_ENV=production"
          "PASEO_HOME=${homeDir}/.paseo"
          "PASEO_LISTEN=127.0.0.1:6767"
          "PASEO_HOSTNAMES=.sammohr.dev"
          "PATH=${scriptPath}"
        ];
      };
      Install = {
        WantedBy = [ "default.target" ];
      };
    };
  };
}
