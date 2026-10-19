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
  cfg = config.alerting;
  datasets = config.backup.datasets;

  # JSON secret shape:
  #   {"token":"...","account_id":"...","from":"alerts@send.sammohr.dev","to":"sam@sammohr.dev"}
  # Use a sending subdomain (send.<domain>) so its DMARC/SPF/DKIM records do not
  # interact with the Proton apex records; the from address must match whichever
  # domain/subdomain was onboarded.
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
      pkgs.systemd
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
        if [ -e "$file" ]; then
          mtime=$(stat -c %Y "$file" 2>/dev/null || echo 0)
        else
          # No marker yet (first run since the marker landed). Fall back to the
          # unit's last successful run so epoch 0 does not look ~56 years stale.
          result=$(systemctl show "$unit" -p Result --value 2>/dev/null || true)
          if [ "$result" = "success" ]; then
            last=$(systemctl show "$unit" -p ExecMainExitTimestamp --value 2>/dev/null || true)
            mtime=$(date -d "$last" +%s 2>/dev/null || echo 0)
          else
            mtime=0
          fi
        fi
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
  options.alerting = lib.mkOption {
    type = lib.types.submodule {
      options = {
        enable = lib.mkEnableOption "Cloudflare email alerts for unit failures and stale backups";
        secretFile = lib.mkOption {
          type = lib.types.str;
          default = "/run/secrets/cloudflare-email";
          description = "JSON secret holding the Cloudflare Email Service token, account id, from address, and to address.";
        };
      };
    };
    default = { };
    description = "Send unit-failure and stale-backup email through Cloudflare Email Service. Enable only after the secret and the sending domain exist.";
  };

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
        # The alerted flag must survive between 5-minute runs; without this the
        # directory is removed when the oneshot exits and every run re-emails.
        RuntimeDirectoryPreserve = "yes";
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
