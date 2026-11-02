# Open WebUI is the chat front end for the local llama.cpp server: a personal,
# authenticated web UI that talks OpenAI-compatible HTTP and takes web search
# from the loopback shim in `tinyfish-shim.nix` (the bundled search engines are
# unmaintained API scrapers). Loopback-only; reachability is the tunnel's call.
{ config, lib, ... }:
let
  ports = import ../ports.nix;

  # Tool connections are `ConfigVar`s and `ENABLE_PERSISTENT_CONFIG` is off, so
  # the environment is authoritative and both servers are declared here instead
  # of clicked into the admin UI. The memory listener rejects every request
  # without its sops bearer token; the file server is loopback-only.
  toolServers = [
    {
      type = "mcp";
      url = "http://127.0.0.1:${toString ports.memoryMcp}/mcp";
      path = "";
      auth_type = "bearer";
      key = config.sops.placeholder.memory-mcp-token;
      config.enable = true;
      info = {
        id = "memory";
        name = "memory";
        description = "Agent memory: search, ingest and revisit episodes.";
      };
    }
    {
      type = "mcp";
      url = "http://127.0.0.1:${toString ports.filesMcp}/mcp";
      path = "";
      auth_type = "none";
      key = "";
      config.enable = true;
      info = {
        id = "files";
        name = "filesearch";
        description = "Read-only file search over the server's agent roots.";
      };
    }
  ];
in
{
  # The token reaches Open WebUI only through this rendered file, never the
  # world-readable unit environment.
  sops.templates."open-webui.env".content = ''
    CODE_INTERPRETER_JUPYTER_AUTH_TOKEN=${config.sops.placeholder.jupyter-token}
    TOOL_SERVER_CONNECTIONS=${builtins.toJSON toolServers}
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
      # llama.cpp is the only model backend: one OpenAI-compatible endpoint, no
      # key needed but Open WebUI rejects an empty one.
      OPENAI_API_BASE_URLS = "http://127.0.0.1:${toString ports.llm}/v1";
      OPENAI_API_KEYS = "none";
      # Env is authoritative; the DB must not pin an older config.
      ENABLE_PERSISTENT_CONFIG = "False";
    };
  };

  # The upstream module runs the unit in `stateDir` but only declares
  # StateDirectory=open-webui, which DynamicUser chowns under /var/lib; point it
  # at the same path or the unit starts in a directory nothing creates.
  systemd.services.open-webui.serviceConfig.StateDirectory = lib.mkForce "data/open-webui";
}
