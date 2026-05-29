{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles;
  inherit (cfg) ompWeb;
  enabled = ompWeb.enable && pkgs.stdenv.isLinux;
  port = toString ompWeb.port;
  homeDir = config.home.homeDirectory;
  bunBinDir = "${homeDir}/.bun/bin";
  cacheBinDir = "${homeDir}/.cache/.bun/bin";
  ompBin = "${cacheBinDir}/omp";
  stdioToWsBin = "${cacheBinDir}/stdio-to-ws";

  scriptPath =
    "${bunBinDir}:${cacheBinDir}:"
    + lib.makeBinPath [
      pkgs.nodejs
      pkgs.coreutils
    ]
    + ":${homeDir}/.local/bin:${homeDir}/.nix-profile/bin:/run/current-system/sw/bin:/run/wrappers/bin";

  bridgeScript = pkgs.writeShellScript "omp-acp-bridge" ''
    exec ${stdioToWsBin} \
      "${ompBin} --mode acp" \
      --port ${port} \
      --persist \
      --grace-period ${toString ompWeb.gracePeriod}
  '';
in
{
  home.activation.installStdioToWs = lib.mkIf enabled {
    after = [ "linkGeneration" ];
    before = [ ];
    data = ''
      export PATH="${bunBinDir}:${cacheBinDir}:$PATH"
      if ! command -v stdio-to-ws >/dev/null 2>&1; then
        echo "[omp-web] Installing @rebornix/stdio-to-ws..."
        bun install -g @rebornix/stdio-to-ws 2>&1 || true
      fi
    '';
  };

  systemd.user.services.omp-acp-bridge = lib.mkIf enabled {
    Unit = {
      Description = "oh-my-pi ACP WebSocket bridge via stdio-to-ws";
      After = [ "network.target" ];
    };
    Service = {
      Environment = [
        "PATH=${scriptPath}"
      ];
      ExecStart = bridgeScript;
      WorkingDirectory = homeDir;
      Restart = "always";
      RestartSec = 5;
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };
}
