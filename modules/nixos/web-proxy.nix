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
in
{
  config = lib.mkIf (cfg.enable && cfg.tunnelId != "") {
    services.cloudflared = {
      enable = true;
      tunnels.${cfg.tunnelId} = {
        credentialsFile = cfg.credentialsFile;
        default = "http_status:404";
        ingress = {
          ${fqdn "keep"} = upstream 9804;
        }
        // lib.optionalAttrs d.calibre.enable {
          ${fqdn "calibre"} = upstream d.calibre.port;
        };
      };
    };
  };
}
