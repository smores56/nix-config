# Open WebUI: a single-user, phone-friendly chat front end for the local
# llama.cpp model and the Neuralwatt API. It is co-located with both, so every
# upstream is loopback and the service needs no tailnet and no firewall port;
# the tunnel publishes chat.<domain> behind Cloudflare Access (see
# modules/hosts/smortress/meta.nix). The nixpkgs module already hardens the unit
# (DynamicUser, telemetry off). Its `environment` is `{ fixed } // cfg.environment`,
# so overriding it later REPLACES the telemetry defaults wholesale — repeat them
# in any override (and note EnvironmentFile is applied after Environment).
{
  config,
  lib,
  ...
}:
let
  cfg = config.dotfiles.chat;
in
{
  config = lib.mkIf cfg.enable {
    services.open-webui = {
      enable = true;
      host = "127.0.0.1";
      port = cfg.port;
    };
  };
}
