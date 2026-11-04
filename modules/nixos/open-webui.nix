# Chat front end for local llama.cpp; web search comes from the loopback shim in
# tinyfish-shim.nix. Loopback-only; reachability is the tunnel's call.
{
  config,
  pkgs,
  lib,
  aiProviders,
  ...
}:
let
  ports = import ../ports.nix;

  # Backends: local llama.cpp (offline fallback) and Neuralwatt (default). Index order
  # is the contract between OPENAI_API_BASE_URLS and OPENAI_API_KEYS.
  localUrl = aiProviders.smortress.baseUrl;
  inherit (aiProviders) neuralwatt;

  # `ENABLE_PERSISTENT_CONFIG` is off, so the environment is authoritative and tool
  # servers are declared here, not in the admin UI. The memory listener needs its
  # sops bearer token; the file server is loopback-only.
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
    OPENAI_API_KEYS=none;${config.sops.placeholder.neuralwatt-api-key}
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
      # llama.cpp is keyless but Open WebUI rejects an empty key, hence `none`.
      OPENAI_API_BASE_URLS = "${localUrl};${neuralwatt.baseUrl}";
      # Deepseek flash is the default; qwen3.8 is a manual pick (no automatic failover).
      DEFAULT_MODELS = neuralwatt.models.deepseekFlash.id;
      # Defaults inherited by every model so new chats open with the tools on.
      # `utils/models.py` merges this into each model's `info.meta`: `capabilities` merges
      # (per-model wins), other keys are fill-only. MCP tool ids are `server:mcp:<info.id>`,
      # so they match the `info.id` values above.
      DEFAULT_MODEL_METADATA = builtins.toJSON {
        capabilities = {
          web_search = true;
          code_interpreter = true;
        };
        defaultFeatureIds = [
          "web_search"
          "code_interpreter"
        ];
        toolIds = [
          "server:mcp:memory"
          "server:mcp:files"
        ];
      };
      # Env is authoritative; the DB must not pin an older config.
      ENABLE_PERSISTENT_CONFIG = "False";
    };
  };
  # The upstream DynamicUser keeps state under /var/lib/private behind a symlink, which
  # restic archives without following, leaving the chat database out of every snapshot.
  # A static user makes it a real directory in the backed-up tree.
  users.groups.open-webui = { };
  users.users.open-webui = {
    isSystemUser = true;
    group = "open-webui";
  };

  systemd.services.open-webui = {
    serviceConfig = {
      DynamicUser = lib.mkForce false;
      User = "open-webui";
      Group = "open-webui";
      StateDirectory = lib.mkForce "data/open-webui";
      StateDirectoryMode = lib.mkForce "0700";
    };
  };
}
