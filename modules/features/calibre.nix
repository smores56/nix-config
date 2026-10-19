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
  inherit (pkgs.stdenv.hostPlatform) isLinux;
  ports = import ../ports.nix;
  cfg = config.calibre;

  library = "${config.home.homeDirectory}/Calibre Library";
  userdb = "${config.home.homeDirectory}/.config/calibre-server/users.sqlite";

  # The host may point this at a sops-decrypted copy (smortress does); the
  # plaintext XDG file is only the fallback for hosts without a secret.
  passwordFile =
    if cfg.passwordFile != "" then
      cfg.passwordFile
    else
      "${config.home.homeDirectory}/.config/calibre-server/password";

  # Single OPDS account, provisioned from the password file (trailing newlines
  # stripped). Restarting the unit re-applies the file, so rotating the password
  # is just editing the secret and rebuilding.
  opdsUser = "smores56";

  provisionUser = pkgs.writeShellScript "calibre-provision-user" ''
    set -euo pipefail
    server=${lib.getExe' pkgs.calibre "calibre-server"}
    password_file=${lib.escapeShellArg passwordFile}
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
  options.calibre = lib.mkOption {
    type = lib.types.submodule {
      options = {
        enable = lib.mkEnableOption "calibre-server OPDS as a user systemd service";
        port = lib.mkOption {
          type = lib.types.port;
          default = ports.calibre;
          description = "Loopback port for calibre-server.";
        };
        passwordFile = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = "File holding the OPDS account password. Empty falls back to ~/.config/calibre-server/password; smortress points this at its sops-decrypted copy.";
        };
      };
    };
    default = { };
    description = "calibre OPDS content server exposed over the Cloudflare Tunnel.";
  };

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
