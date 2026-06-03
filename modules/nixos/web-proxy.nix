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
  # Outbound-only Cloudflare Tunnel: TLS terminates at the edge, opens no
  # inbound ports, needs no port-forwarding. Each subdomain proxies straight to
  # its loopback service. Held off until a real tunnel UUID exists so a rebuild
  # before the Cloudflare setup does not leave a permanently failing unit.
  config = lib.mkIf (cfg.enable && cfg.tunnelId != "") {
    services.cloudflared = {
      enable = true;
      tunnels.${cfg.tunnelId} = {
        credentialsFile = cfg.credentialsFile;
        default = "http_status:404";
        ingress = {
          ${fqdn "opencode"} = upstream d.opencodeHost.openchamberPort;
          ${fqdn "keep"} = upstream 9804;
          ${fqdn "maki"} = upstream 10530;
        }
        // lib.optionalAttrs d.hermes.enable {
          ${fqdn "hermes"} = upstream 8787;
        };
}
