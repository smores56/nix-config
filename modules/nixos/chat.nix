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
    # The session secret (and, in later tasks, the model keys) reach the service
    # through a systemd EnvironmentFile, which the manager reads as root before
    # dropping to the DynamicUser — so sops' default root ownership is correct.
    # The store path holds a placeholder, not the secret; sops-nix substitutes
    # the real value at activation.
    sops.templates."open-webui-env".content = ''
      WEBUI_SECRET_KEY=${config.sops.placeholder.open-webui-secret-key}
    '';

    services.open-webui = {
      enable = true;
      host = "127.0.0.1";
      port = cfg.port;
      environmentFile = config.sops.templates."open-webui-env".path;
    };
  };
}
