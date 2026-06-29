{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (pkgs.stdenv) isLinux;
  cfg = config.dotfiles.calibre;

  library = "${config.home.homeDirectory}/Calibre Library";
  userdb = "${config.home.homeDirectory}/.config/calibre-server/users.sqlite";
in
{
  config = lib.mkIf (isLinux && cfg.enable) {
    home.packages = [ pkgs.calibre ];

    systemd.user.services.calibre-server = {
      Unit = {
        Description = "calibre OPDS content server";
        After = [ "network.target" ];
      };

      Service = {
        ExecStart = "${lib.getExe' pkgs.calibre "calibre-server"} --port ${toString cfg.port} --listen-on 127.0.0.1 --enable-auth --auth-mode basic --userdb ${lib.escapeShellArg userdb} ${lib.escapeShellArg library}";
        Restart = "on-failure";
        RestartSec = 5;
      };

      Install = {
        WantedBy = [ "default.target" ];
      };
    };
  };
}
