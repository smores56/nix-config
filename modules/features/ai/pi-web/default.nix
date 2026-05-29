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
  homeDir = config.home.homeDirectory;
  piWebBin = "${homeDir}/.cache/.bun/bin/pi-web";
  ompBin = "${homeDir}/.cache/.bun/bin/omp";
  scriptPath = lib.concatStringsSep ":" [
    "${homeDir}/.bun/bin"
    "${homeDir}/.cache/.bun/bin"
    "${homeDir}/.local/bin"
    "${homeDir}/.nix-profile/bin"
    "/run/wrappers/bin"
    "/nix/profile/bin"
    "/etc/profiles/per-user/${config.dotfiles.username}/bin"
    "/nix/var/nix/profiles/default/bin"
    "/run/current-system/sw/bin"
  ];
in
{
  systemd.user.services.pi-web = lib.mkIf (piWebEnabled && pkgs.stdenv.isLinux) {
    Unit = {
      Description = "oh-my-pi Web UI";
      After = [ "network.target" ];
    };
    Service = {
      Environment = [
        "PATH=${scriptPath}"
      ];
      ExecStartPre = pkgs.writeShellScript "pi-web-patch-agent-cmd" ''
        SERVER_JS="${homeDir}/.cache/.bun/install/cache/pi-web@0.14.0@@@1/build/server/server.js"
        if [ -f "$SERVER_JS" ]; then
          ${pkgs.gnused}/bin/sed -i \
            -e 's|{ command: .npx., args: \[.-y., .@earendil-works/pi-coding-agent@latest.\] }|{ command: "${ompBin}", args: [] }|' \
            -e 's|{ command: .npx., args: \[.-y., .@oh-my-pi/pi-coding-agent@latest.\] }|{ command: "${ompBin}", args: [] }|' \
            "$SERVER_JS"
        fi
      '';
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
