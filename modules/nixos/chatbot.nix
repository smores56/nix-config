# Self-hosted, phone-friendly chat bot: Open WebUI + SearXNG + a sandboxed
# read-only filesystem reader. No code execution, no agents, no RAG sync —
# files are read live through the reader, never copied into a vector store.
#
# Provisioning, out of band and root-owned 0600 (KEYS NEVER GO IN THE STORE):
#   install -d -m 700 /etc/open-webui
#   umask 077
#   printf 'WEBUI_SECRET_KEY=%s\nSEARXNG_SECRET=%s\nOPENAI_API_KEY=%s\n' \
#     "$(openssl rand -hex 32)" "$(openssl rand -hex 32)" "$NEURALWATT_API_KEY" \
#     > /etc/open-webui/secrets.env
#
# First run: set dotfiles.chatbot.allowSignup = true, rebuild, create the admin
# account, then set it back to false and rebuild again.
#
# Reach it from a phone. The PWA needs a real HTTPS origin (its service worker
# will not install over plain HTTP, and WireGuard encryption does not count),
# and `/` is already served by the ttyd rule:
#   tailscale serve --bg --https=8443 http://127.0.0.1:8080
#
# Then in the UI: Admin -> Settings -> Integrations -> Tools -> Add -> OpenAPI,
# URL http://127.0.0.1:8099/openapi.json, no auth; attach it to your model.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles.chatbot;

  # uvicorn + fastapi for the read-only filesystem tool server.
  readerPython = pkgs.python3.withPackages (ps: [
    ps.fastapi
    ps.uvicorn
  ]);

  # The app is a single module; PYTHONPATH points at it so the service reads it
  # straight from the store and never writes there.
  readerApp = pkgs.runCommand "chatbot-fs-reader-src" { } ''
    mkdir -p $out
    cp ${./chatbot-src/fs_reader.py} $out/fs_reader.py
    cp ${./chatbot-src/path_guard.py} $out/path_guard.py
  '';

  fileRoots = map toString cfg.fileRoots;
in
{
  config = lib.mkIf cfg.enable {
    # ── Web search backend ──────────────────────────────────────────────────
    services.searx = {
      enable = true;
      environmentFile = cfg.secretsFile;
      settings = {
        server = {
          port = cfg.searxPort;
          # Internal-only: the bot-protection limiter would only throttle
          # Open WebUI's own requests.
          limiter = false;
          image_proxy = false;
          public_instance = false;
        };
        search = {
          # Open WebUI queries the JSON API; SearXNG ships html-only.
          formats = [
            "html"
            "json"
          ];
          safe_search = 0;
        };
      };
    };

    # ── Chat UI ─────────────────────────────────────────────────────────────
    # The nixpkgs module already sandboxes this hard: DynamicUser,
    # ProtectHome=true (it never sees a home directory — files arrive only via
    # the reader below), empty CapabilityBoundingSet, SystemCallFilter.
    services.open-webui = {
      enable = true;
      host = "127.0.0.1";
      inherit (cfg) port;
      environmentFile = cfg.secretsFile;
      environment = {
        ENABLE_OPENAI_API = "True";
        OPENAI_API_BASE_URL = cfg.providerBaseUrl;
        # Removes Open WebUI's in-process Python surface, which upstream
        # documents as equivalent to granting shell access on the host.
        ENABLE_PLUGINS = "False";
        USER_PERMISSIONS_WORKSPACE_TOOLS_ACCESS = "False";
        # Keep environment variables authoritative over the settings database.
        ENABLE_PERSISTENT_CONFIG = "False";
        ENABLE_SIGNUP = if cfg.allowSignup then "True" else "False";
        ENABLE_VERSION_UPDATE_CHECK = "False";
        ENABLE_WEB_SEARCH = "True";
        WEB_SEARCH_ENGINE = "searxng";
        SEARXNG_QUERY_URL = "http://127.0.0.1:${toString cfg.searxPort}/search?q=<query>";
        SEARXNG_LANGUAGE = "all";
        # RAG is deliberately unused, so no embedding model exists; search
        # results are consumed directly instead of being vectorised.
        BYPASS_WEB_SEARCH_EMBEDDING_AND_RETRIEVAL = "True";
      };
    };

    # ── Read-only filesystem tool server ────────────────────────────────────
    # Runs as the owner of the exposed trees, but with the trees mounted
    # read-only and no route off-host, so the blast radius of a compromise is
    # "can read files it was already allowed to read".
    systemd.services.chatbot-fs-reader = {
      description = "Read-only filesystem tool server for Open WebUI";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      environment = {
        PYTHONPATH = readerApp;
        PYTHONDONTWRITEBYTECODE = "1";
        HOME = "/run/chatbot-fs-reader";
        ALLOWED_DIRECTORIES = lib.concatStringsSep ":" fileRoots;
        MAX_READ_BYTES = "262144";
      };

      serviceConfig = {
        Type = "exec";
        ExecStart = "${readerPython}/bin/python -m uvicorn fs_reader:app --host 127.0.0.1 --port ${toString cfg.readerPort}";
        User = config.dotfiles.username;

        RuntimeDirectory = "chatbot-fs-reader";
        WorkingDirectory = "/run/chatbot-fs-reader";
        Restart = "on-failure";

        # Read-only view of exactly the exposed trees.
        ProtectHome = "read-only";
        ReadOnlyPaths = fileRoots;
        ProtectSystem = "strict";

        PrivateTmp = true;
        PrivateDevices = true;
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        DevicePolicy = "closed";
        LockPersonality = true;
        ProtectClock = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        ProtectProc = "invisible";
        ProcSubset = "all";
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
        ];

        # Loopback only, and no egress at all.
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        IPAddressDeny = "any";
        IPAddressAllow = "localhost";

        UMask = "0077";
      };
    };
  };
}
