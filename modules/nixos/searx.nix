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
  ...
}:
let
  cfg = config.dotfiles;
in
{
  config = lib.mkIf cfg.search {
    # SearXNG signs sessions with server.secret_key. searx-init's envsubst
    # substitutes `$SEARX_SECRET_KEY` from this service's EnvironmentFile, so the
    # file must read `SEARX_SECRET_KEY=<key>`. sops decrypts the bare key to a
    # file; render the env-file form from it here so the key never enters the
    # world-readable Nix store.
    sops.templates."searxng-secret".content =
      "SEARX_SECRET_KEY=${config.sops.placeholder.searxng-secret-key}";

    services.searx = {
      enable = true;
      environmentFile = config.sops.templates."searxng-secret".path;
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
  };
}
