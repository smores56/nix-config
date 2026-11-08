# calibre + the FanFicFare CLI (headless story downloads). Agents reach the library through
# the Content server API as the writable OPDS account (modules/nixos/agent-vm.nix hands in the
# password); no process writes the library behind the running server.
# Agents use the guest's `fanficfare-download` wrapper (modules/nixos/agent-vm.nix), which
# applies warning-free title pages and adds or replaces the EPUB in one step. FanFicFare is
# the standalone CLI from pkgs/overlays.nix; it needs no calibre plugin.
# Upstream: https://github.com/JimmXinu/FanFicFare
{
  config,
  lib,
  pkgs,
  ...
}:
let
  ports = import ../ports.nix;
  cfg = config.calibre;

  userdb = "${config.home.homeDirectory}/.config/calibre-server/users.sqlite";

  port = ports.calibre;
  # Single OPDS account from the password file; restarting the unit re-applies it.
  opdsUser = "smores56";

  provisionUser = pkgs.writeShellScript "calibre-provision-user" ''
    set -euo pipefail
    server=${lib.getExe' pkgs.calibre "calibre-server"}
    password_file=${lib.escapeShellArg cfg.passwordFile}
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
    # A read-only account cannot add through the Content server; clear that flag if an earlier
    # setup set it.
    "$server" --manage-users --userdb ${lib.escapeShellArg userdb} -- readonly "${opdsUser}" reset
  '';
in
{
  options.calibre = lib.mkOption {
    type = lib.types.submodule {
      options = {
        passwordFile = lib.mkOption {
          type = lib.types.str;
          description = "File holding the OPDS account password; smortress points this at its sops-decrypted copy.";
        };
        library = lib.mkOption {
          type = lib.types.str;
          default = "${config.home.homeDirectory}/Calibre Library";
          description = "Calibre library directory. smortress points this at /var/lib/data/books so it is backed up and writable by the Content server user.";
        };
      };
    };
    default = { };
    description = "calibre OPDS content server exposed over the Cloudflare Tunnel.";
  };

  config = {
    home.packages = [
      pkgs.calibre
      pkgs.fanficfare
    ];

    systemd.user.services.calibre-server = {
      Unit = {
        Description = "calibre OPDS content server";
        After = [ "network.target" ];
      };

      Service = {
        ExecStartPre = provisionUser;
        ExecStart = "${lib.getExe' pkgs.calibre "calibre-server"} --port ${toString port} --listen-on 127.0.0.1 --enable-auth --auth-mode basic --userdb ${lib.escapeShellArg userdb} ${lib.escapeShellArg cfg.library}";
        Restart = "on-failure";
        RestartSec = 5;
      };

      Install = {
        WantedBy = [ "default.target" ];
      };
    };
  };
}
