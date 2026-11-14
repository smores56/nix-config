# Desktop notifications from the cluster's ntfy bus (smores56/sdlc#649).
#
# The bus is the cluster's one notification path: host unit failures, Prometheus
# and Flux alerts, and the agent all publish to it. This subscribes the laptop to
# the two topics it may read (`alerts`, `agent`) as the `reader` user, which
# holds `alerts:ro` and `agent:ro` and nothing else.
#
# The token is read at start from sops and exported as `NTFY_TOKEN`, never
# written into a Nix string: a literal would land world-readable in /nix/store.
# The subscription list is a store-safe config file with no secret in it.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  tokenPath = import ../lib/secret-path.nix config "ntfy-reader-token";

  # ntfy runs each `command` through a shell with the message fields in the
  # environment, so the script only has to map priority to urgency.
  notifySend = pkgs.writeShellApplication {
    name = "ntfy-notify-send";
    runtimeInputs = [ pkgs.libnotify ];
    text = ''
      set -uo pipefail
      case "''${NTFY_PRIORITY:-3}" in
        1 | 2) urgency=low ;;
        4 | 5) urgency=critical ;;
        *) urgency=normal ;;
      esac
      exec notify-send --app-name=ntfy --urgency="$urgency" \
        "''${NTFY_TITLE:-''${NTFY_TOPIC:-ntfy}}" "''${NTFY_MESSAGE:-}"
    '';
  };

  clientConfig = pkgs.writeText "ntfy-client.yml" ''
    # Managed by home-manager (modules/features/notify.nix). No secret here: the
    # token arrives as NTFY_TOKEN from the sops file at start.
    default-host: https://ntfy.sammohr.dev
    subscribe:
      - topic: alerts
        command: ${notifySend}/bin/ntfy-notify-send
      - topic: agent
        command: ${notifySend}/bin/ntfy-notify-send
  '';

  subscribe = pkgs.writeShellApplication {
    name = "ntfy-subscribe";
    runtimeInputs = [
      pkgs.ntfy
      pkgs.coreutils
    ];
    text = ''
      set -euo pipefail
      token_file="''${NTFY_READER_TOKEN_FILE:-${tokenPath}}"
      if [ ! -r "$token_file" ]; then
        echo "ntfy-subscribe: cannot read $token_file" >&2
        exit 1
      fi
      NTFY_TOKEN=$(tr -d '[:space:]' < "$token_file")
      export NTFY_TOKEN
      exec ntfy subscribe --config ${clientConfig} --from-config
    '';
  };
in
{
  systemd.user.services.ntfy-subscribe = {
    Unit = {
      Description = "Desktop notifications from the cluster's ntfy bus";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
    };
    Service = {
      ExecStart = "${subscribe}/bin/ntfy-subscribe";
      # The bus is one replica on a ReadWriteOnce claim, so a drain is downtime;
      # retry rather than give up, but slowly enough not to fill the journal.
      Restart = "on-failure";
      RestartSec = 30;
    };
    Install.WantedBy = [ "default.target" ];
  };
}
