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
  aiProviders,
  ...
}:
let
  cfg = config.dotfiles.chat;
  inherit (aiProviders) neuralwatt smortress;
  ports = import ../ports.nix;
in
{
  config = lib.mkIf cfg.enable {
    # The session secret and the Neuralwatt key reach the service through a
    # systemd EnvironmentFile, which the manager reads as root before dropping
    # to the DynamicUser — so sops' default root ownership is correct. The
    # store path holds placeholders, not secrets; sops-nix substitutes the real
    # values at activation. The local server needs a key too, hence the `;none`.
    sops.templates."open-webui-env".content = ''
      WEBUI_SECRET_KEY=${config.sops.placeholder.open-webui-secret-key}
      OPENAI_API_KEYS=${config.sops.placeholder.neuralwatt-api-key};none
    '';

    services.open-webui = {
      enable = true;
      host = "127.0.0.1";
      port = cfg.port;
      environmentFile = config.sops.templates."open-webui-env".path;
      # The module merges its fixed dirs with this attrset via `//`, so setting
      # any key here REPLACES the option's telemetry defaults wholesale — the
      # three are repeated deliberately. EnvironmentFile is applied after
      # Environment, so the secrets above win over anything here.
      environment = {
        SCARF_NO_ANALYTICS = "True";
        DO_NOT_TRACK = "True";
        ANONYMIZED_TELEMETRY = "False";

        # Two OpenAI-compatible upstreams, in index order: the hosted Neuralwatt
        # API (key from the env file) and local llama.cpp (placeholder key).
        OPENAI_API_BASE_URLS = "${neuralwatt.baseUrl};${smortress.baseUrl}";
        # Namespace each connection so the switcher can tell the two "Qwen 3.8
        # 27B" entries apart; ids become neuralwatt.* and local.*.
        OPENAI_API_CONFIGS = builtins.toJSON {
          "0" = {
            prefix_id = neuralwatt.providerId;
          };
          "1" = {
            prefix_id = "local";
          };
        };
        DEFAULT_MODELS = "${neuralwatt.providerId}.deepseek-v4.1-flash";

        # Web search goes through the co-located SearXNG over loopback; its JSON
        # API is already enabled in modules/nixos/searx.nix. The engine appends
        # `format=json` itself, so only the bare endpoint is needed here.
        ENABLE_WEB_SEARCH = "True";
        WEB_SEARCH_ENGINE = "searxng";
        SEARXNG_QUERY_URL = "http://127.0.0.1:${toString ports.searx}/search";
      };
    };
  };
}
