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

  kandevVersion = "0.52.0";
  kandevAsset =
    if pkgs.stdenv.hostPlatform.system == "x86_64-linux" then
      "kandev-linux-x64"
    else if pkgs.stdenv.hostPlatform.system == "aarch64-linux" then
      "kandev-linux-arm64"
    else
      throw "kandev: unsupported platform ${pkgs.stdenv.hostPlatform.system}";
  kandev = pkgs.stdenvNoCC.mkDerivation {
    pname = "kandev";
    version = kandevVersion;
    src = pkgs.fetchurl {
      url = "https://github.com/kdlbs/kandev/releases/download/v${kandevVersion}/${kandevAsset}.tar.gz";
      hash = "sha256-u5uvf8U3WCf4T1WaNAtpB6N0DlK4kNH1r7TzFWp3vfI=";
    };
    sourceRoot = ".";
    installPhase = ''
      install -Dm755 kandev $out/bin/kandev
    '';
  };

  scriptPath = "${homeDir}/.bun/bin:${homeDir}/.cache/.bun/bin:${homeDir}/.opencode/bin:${homeDir}/.local/bin:" + lib.makeBinPath [
    pkgs.nodejs
    pkgs.coreutils
    pkgs.git
  ] + ":${homeDir}/.nix-profile/bin:/run/current-system/sw/bin:/run/wrappers/bin";
in
{
  config = lib.mkIf enabled {
    home.packages = [ kandev ];

    systemd.user.services.kandev = {
      Unit = {
        Description = "Kandev AI development environment";
        After = [ "network.target" ];
      };
      Service = {
        Environment = [
          "PATH=${scriptPath}"
          "KANDEV_SERVER_HOST=${cfg.bindAddress}"
          "KANDEV_SERVER_PORT=${toString cfg.port}"
          "KANDEV_HOME_DIR=${homeDir}/.kandev"
          "KANDEV_DOCKER_ENABLED=false"
          "HOME=${homeDir}"
        ];
        ExecStart = "${kandev}/bin/kandev start --backend-port ${toString cfg.port} --web-port ${toString (cfg.port - 1000)}";
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
