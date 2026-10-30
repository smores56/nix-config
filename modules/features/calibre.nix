# calibre + FanFicFare CLI workflow (headless story downloads), plus an
# ingest queue so an agent can add books and edit metadata without holding the
# OPDS password or stopping the server itself:
#   1. install the FanFicFare plugin zip once:
#      calibre-debug -c "from calibre.customize.ui import add_plugin; add_plugin('/tmp/FanFicFarePlugin.zip')"
#   2. download: calibre-debug --run-plugin FanFicFare -- --with-library "$HOME/Calibre Library" <story-url>
#      (writes the epub to CWD; does not add it to the library)
#   3. calibredb add refuses while calibre-server holds the library: the ingest
#      service below stops this unit, runs calibredb, and starts it again.
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

  # The agent writes books and a manifest.json to the queue. The service owns
  # the calibre lock: stop the OPDS server, apply the manifest and add books,
  # restart. Processed/failed move out of the queue so a failed file is not
  # retried forever.
  ingest = pkgs.writeShellApplication {
    name = "calibre-ingest";
    runtimeInputs = [
      pkgs.calibre
      pkgs.coreutils
      pkgs.findutils
      pkgs.jq
      pkgs.systemd
    ];
    text = ''
      set -euo pipefail
      inbox=${lib.escapeShellArg cfg.ingestDir}
      library=${lib.escapeShellArg cfg.library}
      canonical=${lib.escapeShellArg cfg.ingestDir}

      # The queue lives in an agent-writable tree. Refuse a symlinked queue or
      # processed/failed directories, and confine every manifest path to the
      # queue; otherwise this timer is an unsandboxed arbitrary-file reader
      # (and mover) for the agent.
      [ -d "$inbox" ] && [ ! -L "$inbox" ] || exit 0
      [ "$(realpath -e "$inbox")" = "$canonical" ] || {
        echo "calibre-ingest: queue is a symlink or relocated: $inbox" >&2
        exit 1
      }
      for sub in processed failed; do
        if [ -L "$inbox/$sub" ]; then
          echo "calibre-ingest: $inbox/$sub is a symlink" >&2
          exit 1
        fi
        mkdir -p "$inbox/$sub"
      done
      manifest="$inbox/manifest.json"
      if [ -L "$manifest" ]; then
        echo "calibre-ingest: manifest is a symlink" >&2
        exit 1
      fi

      safe_file() {
        local p=$1 candidate
        case "$p" in
          "" | /* | *..*) return 1 ;;
        esac
        candidate=$(realpath -m "$inbox/$p") || return 1
        case "$candidate" in
          "$canonical"/*) ;;
          *) return 1 ;;
        esac
        [ -f "$candidate" ] && [ ! -L "$candidate" ] || return 1
        printf '%s' "$candidate"
      }

      mapfile -d "" -t entries < <(find "$inbox" -mindepth 1 -maxdepth 1 -type f ! -name manifest.json -printf '%f\0')
      [ -f "$manifest" ] || [ "''${#entries[@]}" -gt 0 ] || exit 0

      systemctl --user stop calibre-server.service || true
      trap 'systemctl --user start calibre-server.service || true' EXIT

      if [ -f "$manifest" ]; then
        if ! jq -e 'type == "array"' "$manifest" >/dev/null; then
          echo "calibre-ingest: manifest is not a JSON array" >&2
          mv "$manifest" "$inbox/failed/manifest.$(date +%s).json"
        else
          jq -c '.[]' "$manifest" | while IFS= read -r entry; do
            op=$(jq -r '.op' <<<"$entry")
            case "$op" in
              add)
                path=$(jq -r '.path' <<<"$entry")
                file=$(safe_file "$path") || {
                  echo "calibre-ingest: rejected manifest path: $path" >&2
                  continue
                }
                if calibredb add --with-library "$library" "$file"; then
                  mv "$file" "$inbox/processed/"
                else
                  mv "$file" "$inbox/failed/"
                fi
                ;;
              set_metadata)
                id=$(jq -r '.id' <<<"$entry")
                while IFS= read -r field; do
                  calibredb set_metadata --with-library "$library" "$id" --field "$field" \
                    || true
                done < <(jq -r '.fields | to_entries[] | "\(.key):\(.value)"' <<<"$entry")
                ;;
            esac
          done
          mv "$manifest" "$inbox/processed/manifest.$(date +%s).json"
        fi
      fi

      for name in "''${entries[@]}"; do
        [ -f "$inbox/$name" ] && [ ! -L "$inbox/$name" ] || continue
        if calibredb add --with-library "$library" "$inbox/$name"; then
          mv "$inbox/$name" "$inbox/processed/"
        else
          mv "$inbox/$name" "$inbox/failed/"
        fi
      done
    '';
  };

  # One-shot data migration to the media dataset. It is deliberately not an
  # activation step: moving the library is an operator decision.
  migrate = pkgs.writeShellApplication {
    name = "calibre-migrate";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.systemd
    ];
    text = ''
      set -euo pipefail
      old="$HOME/Calibre Library"
      new=${lib.escapeShellArg cfg.library}
      if [ -e "$new/metadata.db" ]; then
        echo "calibre-migrate: $new already exists" >&2
        exit 0
      fi
      if [ ! -d "$old" ]; then
        echo "calibre-migrate: $old is missing; nothing to move" >&2
        exit 0
      fi
      systemctl --user stop calibre-server.service || true
      mkdir -p "$(dirname "$new")"
      mv "$old" "$new"
      systemctl --user start calibre-server.service || true
      echo "calibre-migrate: moved $old -> $new" >&2
    '';
  };
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
        library = lib.mkOption {
          type = lib.types.str;
          default = "${config.home.homeDirectory}/Calibre Library";
          description = "Calibre library directory. smortress points this at /var/lib/media/Calibre so it is backed up and writable by the agent queue.";
        };
        ingestDir = lib.mkOption {
          type = lib.types.str;
          default = "/var/lib/media/Calibre-Ingest";
          description = "Queue the agent writes books and manifest.json to; a user timer runs calibredb with the server stopped.";
        };
      };
    };
    default = { };
    description = "calibre OPDS content server exposed over the Cloudflare Tunnel.";
  };

  config = lib.mkIf (isLinux && cfg.enable) {
    home.packages = [
      pkgs.calibre
      ingest
      migrate
    ];

    systemd.user.services.calibre-server = {
      Unit = {
        Description = "calibre OPDS content server";
        After = [ "network.target" ];
      };

      Service = {
        ExecStartPre = provisionUser;
        ExecStart = "${lib.getExe' pkgs.calibre "calibre-server"} --port ${toString cfg.port} --listen-on 127.0.0.1 --enable-auth --auth-mode basic --userdb ${lib.escapeShellArg userdb} ${lib.escapeShellArg cfg.library}";
        Restart = "on-failure";
        RestartSec = 5;
      };

      Install = {
        WantedBy = [ "default.target" ];
      };
    };

    systemd.user.services.calibre-ingest = {
      Unit = {
        Description = "Add queued books and metadata to the calibre library";
      };
      Service = {
        Type = "oneshot";
        ExecStart = lib.getExe ingest;
        # The service itself stops/starts calibre-server; no After= ordering.
      };
    };

    systemd.user.timers.calibre-ingest = {
      Unit = {
        Description = "Run the calibre ingest queue";
      };
      Timer = {
        OnBootSec = "1min";
        OnUnitActiveSec = "1min";
        Persistent = true;
      };
      Install = {
        WantedBy = [ "timers.target" ];
      };
    };
  };
}
