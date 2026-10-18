# Self-hosted SearXNG (meta search) so the agent's web search stays on
# infrastructure we own instead of paying a search vendor. Only the host with
# `dotfiles.search = true` runs it — currently smortress, always on. It binds
# loopback: the Cloudflare Tunnel proxies searx.<domain> to it, and the tunnel's
# Access app is the only way in.
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
    assertions = [
      {
        assertion = config.sops.secrets ? searxng-secret-key;
        message = "dotfiles.search = true requires a `searxng-secret-key` sops secret declared for this host (see modules/nixos/secrets.nix).";
      }
    ];

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
      # The limiter is deliberately off. Its JSON API cap is a hardcoded
      # `API_MAX = 4` requests per hour (botdetection/ip_limit.py), which the
      # maki websearch plugin blows through immediately; it also cannot
      # attribute clients here, because the Cloudflare Tunnel is a TCP ingress,
      # so no X-Forwarded-For reaches SearXNG and every client looks like
      # 127.0.0.1. Cloudflare Access (email allow-list + service token) gates
      # the hostname instead, so the local Redis the limiter needs is not
      # created either. JSON stays on for the maki plugin.
      settings = {
        server = {
          bind_address = "127.0.0.1";
          port = cfg.searchPort;
          secret_key = "$SEARX_SECRET_KEY";
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
