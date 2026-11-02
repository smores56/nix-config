# Open WebUI is the chat front end for the local llama.cpp server: a personal,
# authenticated web UI that talks OpenAI-compatible HTTP and takes web search
# from the loopback shim in `tinyfish-shim.nix` (the bundled search engines are
# unmaintained API scrapers). Loopback-only; reachability is the tunnel's call.
{ config, lib, ... }:
let
  ports = import ../ports.nix;
in
{
  sops.templates."open-webui.env".content = ''
    CODE_INTERPRETER_JUPYTER_AUTH_TOKEN=${config.sops.placeholder.jupyter-token}
    MEMORY_MCP_TOKEN=${config.sops.placeholder.memory-mcp-token}
  '';

  services.open-webui = {
    enable = true;
    host = "127.0.0.1";
    port = ports.openWebui;
    stateDir = "/var/lib/data/open-webui";
    environmentFile = config.sops.templates."open-webui.env".path;

    environment = {
      WEBUI_AUTH = "True";
      ENABLE_WEB_SEARCH = "True";
      WEB_SEARCH_ENGINE = "external";
      EXTERNAL_WEB_SEARCH_URL = "http://127.0.0.1:8899/search";
      EXTERNAL_WEB_SEARCH_API_KEY = "loopback";
      ENABLE_CODE_INTERPRETER = "True";
      CODE_INTERPRETER_ENGINE = "jupyter";
      CODE_INTERPRETER_JUPYTER_URL = "http://127.0.0.1:8888/";
      CODE_INTERPRETER_JUPYTER_AUTH = "token";
      # Env is authoritative; the DB must not pin an older config.
      ENABLE_PERSISTENT_CONFIG = "False";
    };
  };

  # The upstream module runs the unit in `stateDir` but only declares
  # StateDirectory=open-webui, which DynamicUser chowns under /var/lib; point it
  # at the same path or the unit starts in a directory nothing creates.
  systemd.services.open-webui.serviceConfig.StateDirectory = lib.mkForce "data/open-webui";
}
