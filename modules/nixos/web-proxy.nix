{
  config,
  lib,
  ...
}:
let
  d = config.dotfiles;
  cfg = d.webProxy;
in
{
  config = lib.mkIf (cfg.enable && cfg.tunnelName != "") {
    services.cloudflared = {
      enable = true;
      tunnels.${cfg.tunnelName} = {
        inherit (cfg) credentialsFile;
        default = "http_status:404";
        ingress = lib.mapAttrs' (
          sub: s: lib.nameValuePair "${sub}.${cfg.domain}" "http://127.0.0.1:${toString s.port}"
        ) cfg.services;
      };
    };
  };
}
