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

  paseoIngress =
    if d.paseo.enable && d.paseo.web.enable then
      { ${fqdn "paseo"} = upstream d.paseo.web.port; }
    else if d.paseo.enable then
      { ${fqdn "paseo"} = upstream 6767; }
    else
      { };
in
{
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
        }
        // lib.optionalAttrs d.piDashboard.enable {
          ${fqdn "pi"} = upstream 12321;
        }
        // lib.optionalAttrs d.tau.enable {
          ${fqdn "omp"} = upstream d.tau.port;
        }
        // paseoIngress
        // lib.optionalAttrs d.herdr.enable {
          ${fqdn "herdr"} = upstream d.herdr.port;
        }
        // lib.optionalAttrs d.agentOfEmpires.enable {
          ${fqdn "aoe"} = upstream d.agentOfEmpires.port;
        }
        // lib.optionalAttrs d.goose.web.enable {
          ${fqdn "goose"} = upstream d.goose.web.port;
        };
      };
    };
  };
}
