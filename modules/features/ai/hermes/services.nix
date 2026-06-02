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
          # The Python ssl module can't find the system CA bundle on NixOS
          # without this pointer (hermes model catalog fetches fail otherwise).
          "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
          # Cloudflared forwards Host: hermes.<domain> but not X-Forwarded-Host,
          # so the dashboard can't reconstruct its public URL and rejects the
          # Host header. Tell it the canonical public URL explicitly.
          "HERMES_DASHBOARD_PUBLIC_URL=https://hermes.${config.dotfiles.webProxy.domain}"
          # Disable Hermes' own OAuth/host gate: Cloudflare Access is the auth
          # layer in front; without this the dashboard rejects any non-bind Host.
          "HERMES_DASHBOARD_INSECURE=1"
        ];
        # Loopback only + --insecure: Cloudflare Access is the auth layer, but
        # binding 127.0.0.1 prevents LAN discovery. The CLI --insecure flag is
        # required because the auth gate also checks the bind host (env var
        # HERMES_DASHBOARD_INSECURE isn't read early enough for the bind check).
        ExecStart = "${hermesBin} dashboard --tui --no-open --insecure --host 127.0.0.1 --port ${toString cfg.dashboard.port}";
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
