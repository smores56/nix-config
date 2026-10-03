# Self-hosted SearXNG (meta search) so the agent's web search stays on
# infrastructure we own instead of paying a search vendor. Only the host with
# `dotfiles.search = true` runs it — currently smortress, which is always on and
# reachable over the tailnet. tailscale0 is already a trusted interface
# (modules/nixos/networking.nix), so the port needs no firewall rule and off-LAN
# clients are still dropped.
#
# The maki `websearch` plugin calls the JSON API below; the bundled Exa/You.com
# tool is disabled in the maki module.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles;

  # SearXNG signs sessions with server.secret_key. Keep it off the world-readable
  # Nix store and out of the repo: the oneshot below writes it once under
  # /var/lib, and searx-init's envsubst substitutes $SEARX_SECRET_KEY from this
  # same EnvironmentFile.
  secretFile = "/var/lib/searxng/secrets.env";
in
{
  config = lib.mkIf cfg.search {
    services.searx = {
      enable = true;
      environmentFile = secretFile;
      # No limiter: it exists to throttle untrusted clients and needs Valkey.
      # This instance is tailnet-only; JSON stays on for the maki plugin.
      settings = {
        server = {
          bind_address = "0.0.0.0";
          port = cfg.searchPort;
          secret_key = "$SEARX_SECRET_KEY";
          limiter = false;
        };
        search.formats = [
          "html"
          "json"
        ];
        # DuckDuckGo, Startpage and Brave CAPTCHA-wall this host, which also
        # suspends them and muddies results; keep the engines that answer from
        # here and add a couple more so one flaky engine cannot empty a search.
        engines = [
          {
            name = "duckduckgo";
            disabled = true;
          }
          {
            name = "startpage";
            disabled = true;
          }
          {
            name = "brave";
            disabled = true;
          }
          {
            name = "google";
            disabled = false;
          }
          {
            name = "bing";
            disabled = false;
          }
          {
            name = "mojeek";
            disabled = false;
          }
          {
            name = "wikipedia";
            disabled = false;
          }
        ];
      };
    };

    systemd.services.searx-secret = {
      description = "Generate the SearXNG secret key on first boot";
      before = [ "searx-init.service" ];
      requiredBy = [ "searx-init.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        StateDirectory = "searxng";
        StateDirectoryMode = "0700";
        # The redirect would otherwise inherit systemd's 0022 and leave the key
        # readable by every local user.
        UMask = "0077";
        ExecStart = pkgs.writeShellScript "searx-secret" ''
          set -eu
          file=${lib.escapeShellArg secretFile}
          # `-s`, not `-e`: an empty file from an interrupted first boot would
          # let envsubst substitute a blank secret and SearXNG still start.
          if [ ! -s "$file" ]; then
            printf 'SEARX_SECRET_KEY=%s\n' \
              "$(${pkgs.coreutils}/bin/head -c 32 /dev/urandom | ${pkgs.coreutils}/bin/base64 | ${pkgs.coreutils}/bin/tr -d '\n')" \
              > "$file"
          fi
        '';
      };
    };
  };
}
