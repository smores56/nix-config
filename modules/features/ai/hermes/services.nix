{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles.hermes;
  enabled = cfg.enable && pkgs.stdenv.isLinux;

  homeDir = config.home.homeDirectory;
  hermesBin = "${homeDir}/.hermes/hermes-agent/venv/bin/hermes";

  # User services get a minimal PATH; give them the docker client (system
  # profile), node (for the dashboard's embedded TUI), the venv, and the
  # installer-managed node/local bins.
  svcPath = lib.concatStringsSep ":" [
    "${homeDir}/.hermes/hermes-agent/venv/bin"
    "${homeDir}/.hermes/node/bin"
    "${homeDir}/.local/bin"
    "/run/current-system/sw/bin"
    "/run/wrappers/bin"
    (lib.makeBinPath [
      pkgs.coreutils
      pkgs.bashInteractive
      pkgs.git
      pkgs.nodejs_22
    ])
  ];
in
{
  systemd.user.services = {
    hermes-dashboard = lib.mkIf (enabled && cfg.dashboard.enable) {
      Unit = {
        Description = "Hermes Agent web dashboard (chat + management)";
        After = [ "network.target" ];
      };
      Service = {
        Environment = [
          "PATH=${svcPath}"
          "HERMES_DASHBOARD_TUI=1"
        ];
        # Bound to localhost on purpose — expose only via `hermes-dashboard-serve`
        # (Tailscale Serve). The dashboard has no auth and reads/writes .env.
        ExecStart = "${hermesBin} dashboard --tui --no-open --host 127.0.0.1 --port ${toString cfg.dashboard.port}";
        WorkingDirectory = homeDir;
        Restart = "always";
        RestartSec = 5;
      };
      Install = {
        WantedBy = [ "default.target" ];
      };
    };

    hermes-gateway = lib.mkIf (enabled && cfg.gateway.enable) {
      Unit = {
        Description = "Hermes Agent messaging gateway (Discord, etc.)";
        After = [ "network.target" ];
      };
      Service = {
        Environment = [
          "PATH=${svcPath}"
        ];
        ExecStart = "${hermesBin} gateway run";
        WorkingDirectory = homeDir;
        Restart = "always";
        RestartSec = 5;
      };
      Install = {
        WantedBy = [ "default.target" ];
      };
    };
  };
}
