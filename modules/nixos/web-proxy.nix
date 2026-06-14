{
  config,
  lib,
  ...
}:
let
  d = config.dotfiles;
  cfg = d.webProxy;

  fqdn = sub: "${sub}.${cfg.domain}";
  upstream = port: "http://127.0.0.1:${toString port}";

  # The Paseo daemon serves only an API (/api/*) and a WebSocket (/ws); GET /
  # is a 404, it has no browseable page. To make the bare https://<fqdn>/ open
  # the portal, nginx fronts the daemon: an exact-match `= /` 302s browsers to
  # app.paseo.sh (which auto-reconnects to the saved daemon), while /ws + /api
  # proxy straight through. /ws is the only socket path, so the exact root match
  # never intercepts a live connection.
  paseoPortalPort = 6766;
in
{
  config = lib.mkIf (cfg.enable && cfg.tunnelId != "") {
    services.nginx = lib.mkIf d.paseo.enable {
      enable = true;
      recommendedProxySettings = true;
      virtualHosts.${fqdn d.paseo.subdomain} = {
        listen = [
          {
            addr = "127.0.0.1";
            port = paseoPortalPort;
          }
        ];
        locations."= /".return = "302 https://app.paseo.sh/";
        locations."/" = {
          proxyPass = upstream d.paseo.port;
          proxyWebsockets = true;
          extraConfig = ''
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
          '';
        };
      };
    };

    services.cloudflared = {
      enable = true;
      tunnels.${cfg.tunnelId} = {
        credentialsFile = cfg.credentialsFile;
        default = "http_status:404";
        ingress = {
          ${fqdn "keep"} = upstream 9804;
        }
        // lib.optionalAttrs d.piDashboard.enable {
          ${fqdn "pi"} = upstream 12321;
        }
        // lib.optionalAttrs d.paseo.enable {
          ${fqdn d.paseo.subdomain} = upstream paseoPortalPort;
        };
      };
    };
  };
}
