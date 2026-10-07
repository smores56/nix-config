# Service-failure alerting: a self-hosted ntfy server plus a template handler
# any watched unit points at with `onFailure = [ "notify@%n.service" ]`. Do not
# hardcode that string — read and gate on the option so a host that has not
# enabled notify does not reference a template that does not exist:
#
#   systemd.services.my-thing.onFailure =
#     lib.optional config.dotfiles.notify.enable config.dotfiles.notify.unit;
#
# The handler publishes to the loopback listener, so alerts work without the
# public ntfy.<domain> exposure (that only adds browser access behind Cloudflare
# Access). The topic is generated once at /var/lib/ntfy-alert/topic and never
# enters the Nix store; read it as root and poll the loopback listener to fetch
# alerts. Known limits: ntfy runs on this host, so it cannot report the host
# itself being down; and the mobile app cannot pass Cloudflare Access, so
# consume alerts in the browser.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles.notify;

  # Instance-templated: watchers instantiate us as notify@%n.service, so %i is
  # the full name of the failing unit (e.g. backup-photos.service). systemd
  # passes the failed invocation's ID and result to OnFailure handlers; scope
  # the log to that exact run and fall back to the unit's last lines otherwise.
  notifyScript = ''
    set -eu
    unit="$1"

    if [ -n "''${MONITOR_INVOCATION_ID:-}" ]; then
      log="$(${pkgs.systemd}/bin/journalctl _SYSTEMD_INVOCATION_ID="$MONITOR_INVOCATION_ID" -n 20 --no-pager -o cat)"
    else
      log="$(${pkgs.systemd}/bin/journalctl -u "$unit" -n 20 --no-pager -o cat)"
    fi

    title="$unit failed"
    if [ -n "''${MONITOR_SERVICE_RESULT:-}" ]; then
      title="$title (result=$MONITOR_SERVICE_RESULT)"
    fi
    if [ -n "''${MONITOR_EXIT_CODE:-}" ]; then
      title="$title exit=$MONITOR_EXIT_CODE"
    fi

    topic="$(cat ${lib.escapeShellArg cfg.topicFile})"

    # The topic is the only secret guarding the listener, and any local user can
    # read another process's argv via /proc, so it must never be a curl argument.
    # Buffer URL and body in the unit's private tmp: a file also lets curl's
    # retries re-read the journal (a retried pipe would POST an empty body, which
    # ntfy renders as the useless literal "triggered").
    scratch="$(mktemp -d)"
    trap 'rm -rf "$scratch"' EXIT
    chmod 700 "$scratch"
    printf 'url = "http://127.0.0.1:%s/%s"\n' "${toString cfg.ntfyPort}" "$topic" > "$scratch/curl.conf"
    printf '%s' "$log" > "$scratch/body"
    chmod 600 "$scratch/curl.conf" "$scratch/body"

    # Journal bytes are arbitrary, so they go in the body, never a header.
    ${pkgs.curl}/bin/curl -s --max-time 15 --retry 3 --fail \
      -H "Title: $title" \
      --data-binary @"$scratch/body" \
      --config "$scratch/curl.conf"
  '';
in
{
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion =
          !(config.dotfiles.webProxy.services ? ntfy) || config.dotfiles.webProxy.services.ntfy.access.enable;
        message = "dotfiles.webProxy.services.ntfy must set access.enable = true: the local ntfy listener is unauthenticated, so exposing it publicly without Cloudflare Access would leave the topic open to anyone who learns it.";
      }
    ];

    services.ntfy-sh = {
      enable = true;
      settings = {
        listen-http = "127.0.0.1:${toString cfg.ntfyPort}";
        base-url = "https://ntfy.${config.dotfiles.webProxy.domain}";
        behind-proxy = true;
        # The handler publishes anonymously over loopback; the public path is
        # guarded by Cloudflare Access. read-write is ntfy's anonymous default,
        # i.e. auth stays off on the local listener.
        auth-default-access = "read-write";
      };
    };

    # Generate the topic once. `-s`, not `-e`: an empty file from an interrupted
    # first boot would otherwise publish to a blank topic.
    systemd.services.notify-topic = {
      description = "Generate the ntfy alert topic on first boot";
      before = [ "ntfy-sh.service" ];
      requiredBy = [ "ntfy-sh.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        StateDirectory = "ntfy-alert";
        StateDirectoryMode = "0700";
        # The redirect would otherwise inherit systemd's 0022 and leave the
        # topic readable by every local user.
        UMask = "0077";
        ExecStart = pkgs.writeShellScript "notify-topic" ''
          set -eu
          file=${lib.escapeShellArg cfg.topicFile}
          if [ ! -s "$file" ]; then
            # 18 random bytes -> exactly 24 base64 chars, no padding; mapped to
            # the URL-safe alphabet ntfy topics use.
            ${pkgs.coreutils}/bin/head -c 18 /dev/urandom \
              | ${pkgs.coreutils}/bin/base64 \
              | ${pkgs.coreutils}/bin/tr '+/' '-_' \
              | ${pkgs.coreutils}/bin/tr -d '=\n' \
              > "$file"
          fi
        '';
      };
    };

    systemd.services."notify@" = {
      description = "Push a unit-failure notification to ntfy";
      after = [ "ntfy-sh.service" ];
      # %i is the full failing unit name including the .service suffix; do not
      # append it again.
      scriptArgs = "%i";
      script = notifyScript;
      serviceConfig = {
        Type = "oneshot";
        # Root: journalctl must read any unit's journal.
        User = "root";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
      };
    };
  };
}
