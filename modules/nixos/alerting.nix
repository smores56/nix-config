# Failure alerts to the self-hosted ntfy bus; every backup unit's OnFailure
# targets the template.
#
# The bus is the cluster's one notification path (smores56/sdlc#649). The host
# publishes to the public hostname because that is the only route it has: the
# Service is in-cluster and the host is the tunnel's origin, so the request goes
# out to Cloudflare and back through the tunnel it may be reporting on. The
# cluster's own alerts do not take that path -- `notifyrelay` posts to the
# Service -- so a tunnel outage still delivers Prometheus and Flux failures.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  hardening = import ../lib/hardening.nix;
  # Plain-text ntfy access token for the `publisher` user, root-only. That user
  # holds `alerts:wo` and nothing else, so a leaked host token cannot read the
  # bus or page the agent's topic.
  secretFile = "/run/secrets/ntfy-token";
  # The topic is fixed, not derived from the unit name: `%i` is the full unit
  # name (`restic-backups-r2.service`), which contains a dot, fails the broker's
  # path regex and misses `publisher`'s ACL.
  url = "https://ntfy.sammohr.dev/alerts";
  # ntfy rejects a message over `message-size-limit` (16k) with a 413, which
  # would lose the alert entirely. A 50-line journal with long lines can reach
  # that, so the body is capped below it.
  maxBodyBytes = 12000;

  ntfyPublish = pkgs.writeShellApplication {
    name = "ntfy-publish";
    runtimeInputs = [
      pkgs.curl
      pkgs.coreutils
    ];
    text = ''
      set -euo pipefail
      secret="''${NTFY_TOKEN_FILE:-${secretFile}}"
      if [ ! -r "$secret" ]; then
        echo "ntfy-publish: cannot read $secret" >&2
        exit 1
      fi
      token=$(tr -d '[:space:]' < "$secret")
      title="''${1:?title required}"
      body="''${2:-}"
      priority="''${3:-default}"

      # Keep the bearer token out of argv (visible in ps); curl reads the
      # headers from a 0600 temp file instead. Title and priority travel as
      # headers too, so neither has to be URL-encoded into the path.
      headers=$(mktemp)
      payload=$(mktemp)
      truncated=$(mktemp)
      trap 'rm -f "$headers" "$payload" "$truncated"' EXIT
      chmod 600 "$headers"
      printf '%s\n' \
        "Authorization: Bearer $token" \
        "Title: $title" \
        "Priority: $priority" \
        "Content-Type: text/plain; charset=utf-8" > "$headers"

      # `head` reads a file, not a pipe: on a pipe the writer dies of SIGPIPE and
      # `pipefail` would turn a successful publish into a failed unit.
      printf '%s' "$body" > "$payload"
      head -c ${toString maxBodyBytes} "$payload" > "$truncated"

      curl --fail --silent --show-error --retry 3 --retry-delay 5 --max-time 30 \
        --url ${lib.escapeShellArg url} \
        --header @"$headers" \
        --data-binary @"$truncated"
    '';
  };

  onFailure = pkgs.writeShellApplication {
    name = "ntfy-publish-onfailure";
    runtimeInputs = [
      pkgs.systemd
      pkgs.coreutils
      pkgs.bash
    ];
    text = ''
      set -uo pipefail
      unit="''${1:?unit required}"
      body=$(
        { systemctl status --no-pager --full "$unit" || true
          echo
          journalctl -u "$unit" -n 50 --no-pager || true
        } 2>&1
      )
      exec ${ntfyPublish}/bin/ntfy-publish "[${config.networking.hostName}] $unit failed" "$body" high
    '';
  };

  sandbox = hardening // {
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectControlGroups = true;
    ProtectClock = true;
    ProtectHostname = true;
    RestrictSUIDSGID = true;
    RestrictRealtime = true;
    LockPersonality = true;
    RestrictAddressFamilies = [
      "AF_INET"
      "AF_INET6"
      "AF_UNIX"
    ];
  };
in
{
  options.alerting = lib.mkOption {
    type = lib.types.submodule {
      options = {
        accountId = lib.mkOption {
          type = lib.types.str;
          description = "Cloudflare account ID that owns the R2 bucket and the tunnel.";
        };
      };
    };
    description = "Publish unit failures to the self-hosted ntfy bus.";
  };

  config = {
    systemd.services."ntfy-publish@" = {
      description = "Publish the failure of %i to the ntfy bus";
      serviceConfig = sandbox // {
        Type = "oneshot";
        User = "root";
        ExecStart = "${onFailure}/bin/ntfy-publish-onfailure %i";
        Environment = [ "NTFY_TOKEN_FILE=${secretFile}" ];
        TimeoutStartSec = "2m";
      };
    };
  };
}
