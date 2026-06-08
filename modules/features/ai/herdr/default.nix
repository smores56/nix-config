{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles.herdr;
  enabled = cfg.enable && pkgs.stdenv.isLinux;
  homeDir = config.home.homeDirectory;
  scriptPath =
    "${homeDir}/.local/bin:${homeDir}/.nix-profile/bin:${homeDir}/.local/state/nix/profile/bin:"
    + "/etc/profiles/per-user/${config.dotfiles.username}/bin:"
    + "/run/current-system/sw/bin:/run/wrappers/bin:/nix/var/nix/profiles/default/bin";
in
{
  config = lib.mkIf enabled {
    home.packages = [ pkgs.ttyd ];

    systemd.user.services.herdr-ttyd = {
      Unit = {
        Description = "Herdr web terminal (ttyd + herdr session attach default)";
        After = [ "network.target" ];
      };
      Service = {
        Type = "simple";
        ExecStart = "${pkgs.ttyd}/bin/ttyd --writable --port ${toString cfg.port} herdr session attach default";
        Restart = "on-failure";
        RestartSec = 5;
        Environment = [ "PATH=${scriptPath}" ];
      };
      Install = {
        WantedBy = [ "default.target" ];
      };
    };
  };
}
