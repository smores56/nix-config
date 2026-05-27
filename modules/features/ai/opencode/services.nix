{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles;
  inherit (cfg) opencodeHost;
  opencodeEnabled = opencodeHost.bindAddress != null;
  opencodeBackendHost =
    if opencodeHost.bindAddress == "0.0.0.0" then "127.0.0.1" else opencodeHost.bindAddress;
  opencodeBackendUrl = "http://${opencodeBackendHost}:${toString opencodeHost.opencodePort}";
  openchamberBin = "${config.home.homeDirectory}/.cache/.bun/bin/openchamber";
in
{
  systemd.user.services = {
    opencode = lib.mkIf (opencodeEnabled && pkgs.stdenv.isLinux) {
      Unit = {
        Description = "OpenCode Server";
        After = [ "network.target" ];
      };
      Service = {
        Environment = [
          "OPENCODE_HOST=http://localhost:4000"
        ];
        ExecStart = "${config.home.homeDirectory}/.opencode/bin/opencode serve --hostname ${opencodeHost.bindAddress} --port ${toString opencodeHost.opencodePort}";
        WorkingDirectory = config.home.homeDirectory;
        Restart = "always";
        RestartSec = 5;
      };
      Install = {
        WantedBy = [ "default.target" ];
      };
    };

    openchamber = lib.mkIf (opencodeEnabled && pkgs.stdenv.isLinux) {
      Unit = {
        Description = "OpenChamber Web UI";
        After = [
          "network.target"
          "opencode.service"
        ];
        Requires = [ "opencode.service" ];
      };
      Service = {
        Environment = [
          "OPENCODE_HOST=${opencodeBackendUrl}"
          "OPENCODE_BINARY=${config.home.homeDirectory}/.opencode/bin/opencode"
          "OPENCODE_SKIP_START=true"
        ];
        ExecStart = pkgs.writeShellScript "openchamber-serve" ''
          PASSWORD=""
          if [ -f "${config.home.homeDirectory}/.config/openchamber/ui-password" ] && [ -s "${config.home.homeDirectory}/.config/openchamber/ui-password" ]; then
            IFS= read -r PASSWORD < "${config.home.homeDirectory}/.config/openchamber/ui-password"
          fi
          exec ${openchamberBin} serve \
            --port ${toString opencodeHost.openchamberPort} \
            --host ${lib.escapeShellArg opencodeHost.bindAddress} \
            --ui-password "$PASSWORD" \
            --foreground
        '';
        WorkingDirectory = config.home.homeDirectory;
        Restart = "always";
        RestartSec = 5;
      };
      Install = {
        WantedBy = [ "default.target" ];
      };
    };
  };
}
