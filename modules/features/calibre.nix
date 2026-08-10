# calibre + FanFicFare CLI workflow (headless story downloads):
#   1. install the FanFicFare plugin zip once:
#      calibre-debug -c "from calibre.customize.ui import add_plugin; add_plugin('/tmp/FanFicFarePlugin.zip')"
#   2. download: calibre-debug --run-plugin FanFicFare -- --with-library "$HOME/Calibre Library" <story-url>
#      (writes the epub to CWD; does not add it to the library)
#   3. calibredb add refuses while calibre-server holds the library:
#      stop this unit, run calibredb --with-library "$HOME/Calibre Library" add <file>, start again.
# Upstream: https://github.com/JimmXinu/FanFicFare
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

  # Single OPDS account, provisioned from a plaintext XDG password file
  # (trailing newlines stripped). Restarting the unit re-applies the file,
  # so rotating the password is just editing the file.
  opdsUser = "smores56";

  provisionUser = pkgs.writeShellScript "calibre-provision-user" ''
    set -euo pipefail
    server=${lib.getExe' pkgs.calibre "calibre-server"}
    password_file="''${XDG_CONFIG_HOME:-$HOME/.config}/calibre-server/password"
    if [[ ! -r "$password_file" || ! -s "$password_file" ]]; then
      echo "calibre-server: password file missing or empty: $password_file" >&2
      exit 1
    fi
    password="$(<"$password_file")"
    if "$server" --manage-users --userdb ${lib.escapeShellArg userdb} -- list | grep -qx "${opdsUser}"; then
      printf '%s' "$password" | "$server" --manage-users --userdb ${lib.escapeShellArg userdb} -- chpass "${opdsUser}"
    else
      printf '%s' "$password" | "$server" --manage-users --userdb ${lib.escapeShellArg userdb} -- add "${opdsUser}"
    fi
  '';
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
        ExecStartPre = provisionUser;
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
