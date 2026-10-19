# Cloudflare Email Service alerts: unit failures and stale backup markers.
#
# Disabled by default so a host can switch before the Email Service domain,
# API token, and sops secret exist. When enabled, every backup unit's OnFailure
# points at the template, and a 5-minute timer emails once per stale period.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles.alerting;
  datasets = config.dotfiles.backup.datasets;

  # JSON secret shape:
  #   {"token":"...","account_id":"...","from":"alerts@sammohr.dev","to":"sam@sammohr.dev"}
  # The token is the SMTP/REST credential with Email Sending: Edit. The from
  # address must belong to an onboarded Email Service domain; the to address
  # must be verified (sends to verified destinations are free).
  cloudflareEmail = pkgs.writeShellApplication {
    name = "cloudflare-email";
    runtimeInputs = [
      pkgs.curl
      pkgs.jq
      pkgs.coreutils
    ];
    text = ''
      set -euo pipefail
      secret="''${CLOUDFLARE_EMAIL_SECRET:-/run/secrets/cloudflare-email}"
      if [ ! -r "$secret" ]; then
        echo "cloudflare-email: cannot read $secret" >&2
        exit 1
      fi
      token=$(jq -er '.token' "$secret")
      account=$(jq -er '.account_id' "$secret")
      from=$(jq -er '.from' "$secret")
      to=$(jq -er '.to' "$secret")
      subject="''${1:?subject required}"
      body="''${2:-}"

      payload=$(jq -n \
        --arg to "$to" \
        --arg from "$from" \
        --arg subject "$subject" \
        --arg text "$body" \
        '{to:$to,from:$from,subject:$subject,text:$text}')

      # Keep the bearer token out of argv (visible in ps); curl reads the
      # headers from a 0600 temp file instead.
      headers=$(mktemp)
      trap 'rm -f "$headers"' EXIT
      chmod 600 "$headers"
      printf '%s\n' "Authorization: Bearer $token" "Content-Type: application/json" > "$headers"

      curl --fail --silent --show-error --retry 3 --retry-delay 5 --max-time 30 \
        --url "https://api.cloudflare.com/client/v4/accounts/$account/email/sending/send" \
        --header @"$headers" \
        --data "$payload" >/dev/null
    '';
  };

  onFailure = pkgs.writeShellApplication {
    name = "cloudflare-email-onfailure";
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
      exec ${cloudflareEmail}/bin/cloudflare-email "[smortress] $unit failed" "$body"
    '';
  };

  freshness = pkgs.writeShellApplication {
    name = "backup-freshness";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.bash
    ];
    text = ''
      set -euo pipefail
      now=$(date +%s)
      check() {
        name=$1
        max=$2
        unit=$3
        dir="/var/backup/$name"
        # Skip a dataset that has never produced a mirror; there is nothing to
        # be stale yet.
        [ -d "$dir/current" ] || return 0
        file="$dir/BACKUP-LAST-SUCCESS"
        flag="/run/backup-freshness/$name.alerted"
        mtime=$(stat -c %Y "$file" 2>/dev/null || echo 0)
        age=$((now - mtime))
        if [ "$age" -gt "$max" ]; then
          if [ ! -e "$flag" ]; then
            ${cloudflareEmail}/bin/cloudflare-email "backup stale: $name" \
              "No successful $name backup for $((age / 3600))h (limit $((max / 3600))h). Check: systemctl status $unit; journalctl -u $unit" || true
            touch "$flag"
          fi
        else
          rm -f "$flag"
        fi
      }
      ${datasetChecks}
    '';
  };

  datasetChecks = lib.concatMapStringsSep "\n" (
    name:
    "check ${lib.escapeShellArg name} ${
      toString datasets.${name}.freshnessSeconds
    } ${lib.escapeShellArg "backup-${lib.toLower name}"}"
  ) (lib.attrNames datasets);

  sandbox = {
    NoNewPrivileges = true;
    PrivateTmp = true;
    ProtectHome = true;
    ProtectSystem = "strict";
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
  config = lib.mkIf cfg.enable {
    systemd.services."cloudflare-email@" = {
      description = "Email the failure of %i through Cloudflare";
      serviceConfig = sandbox // {
        Type = "oneshot";
        User = "root";
        ExecStart = "${onFailure}/bin/cloudflare-email-onfailure %i";
        Environment = [ "CLOUDFLARE_EMAIL_SECRET=${cfg.secretFile}" ];
        TimeoutStartSec = "2m";
      };
    };

    systemd.services.backup-freshness = {
      description = "Email if a backup dataset's last success is stale";
      serviceConfig = sandbox // {
        Type = "oneshot";
        User = "root";
        ExecStart = "${freshness}/bin/backup-freshness";
        Environment = [ "CLOUDFLARE_EMAIL_SECRET=${cfg.secretFile}" ];
        RuntimeDirectory = "backup-freshness";
        RuntimeDirectoryMode = "0700";
        TimeoutStartSec = "5m";
      };
    };

    systemd.timers.backup-freshness = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "10m";
        OnUnitActiveSec = "5m";
      };
    };
  };
}
