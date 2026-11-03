# Open WebUI is the chat front end for the local llama.cpp server: a personal,
# authenticated web UI that talks OpenAI-compatible HTTP and takes web search
# from the loopback shim in `tinyfish-shim.nix` (the bundled search engines are
# unmaintained API scrapers). Loopback-only; reachability is the tunnel's call.
{
  config,
  pkgs,
  lib,
  aiProviders,
  ...
}:
let
  ports = import ../ports.nix;

  # Two OpenAI-compatible backends: local llama.cpp (qwen3.8, the offline
  # fallback) and Neuralwatt (deepseek-v4.1-flash, the default). Index order is
  # the contract between OPENAI_API_BASE_URLS and OPENAI_API_KEYS.
  localUrl = aiProviders.smortress.baseUrl;
  inherit (aiProviders) neuralwatt;

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
      # Deepseek flash is the default; qwen3.8 stays selectable as the fallback.
      # Open WebUI has no automatic failover, so "backup" is a manual pick.
      DEFAULT_MODELS = neuralwatt.models.deepseekFlash.id;
      # Env is authoritative; the DB must not pin an older config.
      ENABLE_PERSISTENT_CONFIG = "False";
    };
  };
  # The upstream module runs the unit as a DynamicUser. DynamicUser state lives
  # under /var/lib/private with a symlink in /var/lib, and restic archives a
  # symlink without following it, so the chat database would end up in no
  # snapshot at all. A static user makes the state a real directory inside the
  # one backed-up tree.
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
      # One-shot migration: the first start after the static user was introduced
      # replaces the DynamicUser symlink with the real directory. Runs as root
      # because the old files belong to the retired dynamic UID.
      ExecStartPre = "+${pkgs.writeShellScript "open-webui-state-migrate" ''
        set -eu
        dir=/var/lib/data/open-webui
        if [ -L "$dir" ]; then
          target=$(readlink -f "$dir")
          rm "$dir"
          mv "$target" "$dir"
          chown -R open-webui:open-webui "$dir"
          chmod 0700 "$dir"
          rmdir "$(dirname "$target")" 2>/dev/null || true
        fi
      ''}";
    };
  };
}
