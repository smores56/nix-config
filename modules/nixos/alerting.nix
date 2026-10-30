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
      secret="''${CLOUDFLARE_API_TOKEN_FILE:-/run/secrets/cloudflare-api-token}"
      if [ ! -r "$secret" ]; then
        echo "cloudflare-email: cannot read $secret" >&2
        exit 1
      fi
      token=$(tr -d '[:space:]' < "$secret")
      account=${lib.escapeShellArg cfg.accountId}
      from=${lib.escapeShellArg cfg.from}
      to=${lib.escapeShellArg cfg.to}
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
      response=$(mktemp)
      trap 'rm -f "$headers" "$response"' EXIT
      chmod 600 "$headers"
      printf '%s\n' "Authorization: Bearer $token" "Content-Type: application/json" > "$headers"

      curl --fail --silent --show-error --retry 3 --retry-delay 5 --max-time 30 \
        --url "https://api.cloudflare.com/client/v4/accounts/$account/email/sending/send" \
        --header @"$headers" \
        --data "$payload" >"$response"
      # Cloudflare can return HTTP 200 with success:false; only a successful
      # API result counts as delivered.
      if ! jq -e '.success == true' >/dev/null 2>&1 <"$response"; then
        echo "cloudflare-email: send failed: $(cat "$response")" >&2
        exit 1
      fi
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
      exec ${cloudflareEmail}/bin/cloudflare-email "[${config.networking.hostName}] $unit failed" "$body"
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
        dir="${config.backup.mountPoint}/$name"
        # Skip a dataset that has never produced a mirror; there is nothing to
        # be stale yet.
        [ -d "$dir/current" ] || return 0
        file="$dir/BACKUP-LAST-SUCCESS"
        failed="$dir/BACKUP-FAILED"
        deferred="$dir/BACKUP-DEFERRED"
        flag="/run/backup-freshness/$name.alerted"
        if [ -e "$file" ]; then
          mtime=$(stat -c %Y "$file" 2>/dev/null || echo 0)
        elif [ -e "$deferred" ]; then
          # A deferral copied nothing, so there is no successful run to borrow a
          # timestamp from: the dataset is stale by definition, however green the
          # unit looks (a deferral exits 75, which the unit treats as success).
          mtime=0
        else
          # No marker yet (first run since the marker landed). Fall back to the
          # unit's last successful run so epoch 0 does not look ~56 years stale.
          # An empty timestamp means the unit never ran; treat that as no
          # successful backup rather than as fresh.
          result=$(systemctl show "$unit" -p Result --value 2>/dev/null || true)
          last=$(systemctl show "$unit" -p ExecMainExitTimestamp --value 2>/dev/null || true)
          if [ "$result" = "success" ] && [ -n "$last" ]; then
            mtime=$(date -d "$last" +%s 2>/dev/null || echo 0)
          else
            mtime=0
          fi
        fi
        age=$((now - mtime))
        # A failure marker newer than the last success is a live failure the age
        # cannot see: the mirror is unverified even if a recent run finished.
        unverified=0
        if [ -e "$failed" ] && { [ ! -e "$file" ] || [ "$failed" -nt "$file" ]; }; then
          unverified=1
        fi
        if [ "$age" -gt "$max" ] || [ "$unverified" -eq 1 ]; then
          if [ ! -e "$flag" ]; then
            if [ "$unverified" -eq 1 ]; then
              body="The last $name backup failed: $(head -c 300 "$failed" 2>/dev/null || true)"
            elif [ -e "$file" ]; then
              body="No successful $name backup for $((age / 3600))h (limit $((max / 3600))h). Check: systemctl status $unit; journalctl -u $unit"
            else
              body="No successful $name backup recorded (no BACKUP-LAST-SUCCESS marker). Check: systemctl status $unit; journalctl -u $unit"
            fi
            if ${cloudflareEmail}/bin/cloudflare-email "backup stale: $name" "$body"; then
              touch "$flag"
            fi
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
        accountId = lib.mkOption {
          type = lib.types.str;
          description = "Cloudflare account ID that owns the Email Service domain.";
        };
        from = lib.mkOption {
          type = lib.types.str;
          default = "alerts@send.sammohr.dev";
          description = "From address on the onboarded Email Service sending domain.";
        };
        to = lib.mkOption {
          type = lib.types.str;
          default = "sam@sammohr.dev";
          description = "Verified recipient address.";
        };
        secretFile = lib.mkOption {
          type = lib.types.str;
          default = "/run/secrets/cloudflare-api-token";
          description = "File holding the Cloudflare API token (plain text, root-only).";
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
        Environment = [ "CLOUDFLARE_API_TOKEN_FILE=${cfg.secretFile}" ];
        TimeoutStartSec = "2m";
      };
    };

    systemd.services.backup-freshness = {
      description = "Email if a backup dataset's last success is stale";
      serviceConfig = sandbox // {
        Type = "oneshot";
        User = "root";
        ExecStart = "${freshness}/bin/backup-freshness";
        Environment = [ "CLOUDFLARE_API_TOKEN_FILE=${cfg.secretFile}" ];
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
