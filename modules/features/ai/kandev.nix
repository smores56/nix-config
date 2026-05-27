{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles.kandev;
  enabled = cfg.enable && pkgs.stdenv.isLinux;
  homeDir = config.home.homeDirectory;
  port = toString cfg.port;

  scriptPath = "${homeDir}/.bun/bin:${homeDir}/.cache/.bun/bin:${homeDir}/.opencode/bin:${homeDir}/.local/bin:" + lib.makeBinPath [
    pkgs.nodejs
    pkgs.coreutils
    pkgs.git
  ] + ":${homeDir}/.nix-profile/bin:/run/current-system/sw/bin:/run/wrappers/bin";

  kandevStart = pkgs.writeShellScript "kandev-start" ''
    exec npx kandev@latest start --backend-port ${port}
  '';
in
{
  config = lib.mkIf enabled {
    systemd.user.services.kandev = {
      Unit = {
        Description = "Kandev AI development environment";
        After = [ "network.target" ];
      };
      Service = {
        Environment = [
          "PATH=${scriptPath}"
          "KANDEV_SERVER_HOST=${cfg.bindAddress}"
          "KANDEV_SERVER_PORT=${port}"
          "KANDEV_HOME_DIR=${homeDir}/.kandev"
          "KANDEV_DOCKER_ENABLED=false"
          "HOME=${homeDir}"
        ];
        ExecStart = kandevStart;
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
