# Cloudflare Email Service alerts for unit failures.
#
# Every backup unit's OnFailure points at the template, so a failed nightly run
# emails its journal.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.alerting;
  # Plain-text Cloudflare API token, root-only.
  secretFile = "/run/secrets/cloudflare-api-token";
  # On the onboarded Email Service sending domain; the recipient is verified.
  from = "alerts@send.sammohr.dev";
  to = "sam@sammohr.dev";

  # JSON secret shape:
  #   {"token":"...","account_id":"...","from":"alerts@send.sammohr.dev","to":"sam@sammohr.dev"}
  # Use a sending subdomain (send.<domain>) so its DMARC/SPF/DKIM records do not
  # interact with the apex mail records; the from address must match whichever
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
      secret="''${CLOUDFLARE_API_TOKEN_FILE:-${secretFile}}"
      if [ ! -r "$secret" ]; then
        echo "cloudflare-email: cannot read $secret" >&2
        exit 1
      fi
      token=$(tr -d '[:space:]' < "$secret")
      account=${lib.escapeShellArg cfg.accountId}
      from=${lib.escapeShellArg from}
      to=${lib.escapeShellArg to}
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
        accountId = lib.mkOption {
          type = lib.types.str;
          description = "Cloudflare account ID that owns the Email Service domain.";
        };
      };
    };
    description = "Send unit-failure email through Cloudflare Email Service.";
  };

  config = {
    systemd.services."cloudflare-email@" = {
      description = "Email the failure of %i through Cloudflare";
      serviceConfig = sandbox // {
        Type = "oneshot";
        User = "root";
        ExecStart = "${onFailure}/bin/cloudflare-email-onfailure %i";
        Environment = [ "CLOUDFLARE_API_TOKEN_FILE=${secretFile}" ];
        TimeoutStartSec = "2m";
      };
    };
  };
}
