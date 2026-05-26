{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles;
  inherit (cfg) piWeb;
  piWebEnabled = piWeb.enable;
  piWebBin = "${config.home.homeDirectory}/.cache/.bun/bin/pi-web";
in
{
  systemd.user.services.pi-web = lib.mkIf (piWebEnabled && pkgs.stdenv.isLinux) {
    Unit = {
      Description = "Pi Web UI for oh-my-pi";
      After = [ "network.target" ];
    };
    Service = {
      ExecStart = "${piWebBin} --agent omp --host ${piWeb.bindAddress} --port ${toString piWeb.port}";
      WorkingDirectory = config.home.homeDirectory;
      Restart = "always";
      RestartSec = 5;
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };
}
