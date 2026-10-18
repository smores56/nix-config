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
  pkgs,
  aiProviders,
  ...
}:
let
  cfg = config.dotfiles.chat;
  inherit (aiProviders) neuralwatt smortress;
  ports = import ../ports.nix;
  # Minimal server + kernel for the code-interpreter sandbox. Deliberately not
  # `pkgs.jupyter` (the notebook/lab bundle): the sandbox only needs a kernel to
  # run user code, so the smaller closure is less to expose and less to update.
  jupyterEnv = pkgs.python3.withPackages (ps: [
    ps.jupyter-server
    ps.ipykernel
  ]);
  jupyterStateDir = "/var/lib/jupyter-sandbox";
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
      CODE_INTERPRETER_JUPYTER_AUTH_TOKEN=${config.sops.placeholder.jupyter-token}
    '';

    # The sandbox reads its token from JUPYTER_TOKEN, which takes precedence over
    # a generated one (jupyter_server.auth.identity). An EnvironmentFile is the
    # right channel: systemd reads it as root, so the secret file stays 0400 root
    # while the DynamicUser service still receives the value.
    sops.templates."jupyter-env".content = ''
      JUPYTER_TOKEN=${config.sops.placeholder.jupyter-token}
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

        # RAG uses Open WebUI's built-in local embedder: Neuralwatt has no
        # embeddings API, so there is no hosted engine to point at. An empty
        # engine is the "local" one; the ~90 MB model downloads once into
        # SENTENCE_TRANSFORMERS_HOME (under the module's state dir) and runs
        # in-process. Auto-update and trust_remote_code are off to pin the model
        # and avoid executing downloaded code.
        RAG_EMBEDDING_ENGINE = "";
        RAG_EMBEDDING_MODEL = "sentence-transformers/all-MiniLM-L6-v2";
        RAG_EMBEDDING_MODEL_AUTO_UPDATE = "False";
        RAG_EMBEDDING_MODEL_TRUST_REMOTE_CODE = "False";

        # Code interpreter: Open WebUI drives the co-located Jupyter sandbox over
        # loopback, authenticating with the token from the env file.
        ENABLE_CODE_INTERPRETER = "True";
        CODE_INTERPRETER_ENGINE = "jupyter";
        CODE_INTERPRETER_JUPYTER_URL = "http://127.0.0.1:${toString cfg.jupyterPort}";
        CODE_INTERPRETER_JUPYTER_AUTH = "token";
      };
    };

    # The code-interpreter sandbox: a headless Jupyter Server that Open WebUI
    # starts kernels on. Loopback-only, token-auth, its own transient user, and a
    # memory cap; never exposed through the tunnel. Hardened as a service that
    # runs untrusted code, but without SystemCallFilter / MemoryDenyWriteExecute —
    # Python C extensions and JITs need broad syscalls and writable-exec memory.
    systemd.services.jupyter-sandbox = {
      description = "Jupyter sandbox for Open WebUI's code interpreter";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      environment = {
        HOME = jupyterStateDir;
        JUPYTER_RUNTIME_DIR = "/run/jupyter-sandbox";
      };
      serviceConfig = {
        ExecStart = lib.concatStringsSep " " [
          "${jupyterEnv}/bin/jupyter-server"
          "--ServerApp.ip=127.0.0.1"
          "--ServerApp.port=${toString cfg.jupyterPort}"
          "--ServerApp.open_browser=False"
          "--ServerApp.root_dir=${jupyterStateDir}"
        ];
        EnvironmentFile = config.sops.templates."jupyter-env".path;
        StateDirectory = "jupyter-sandbox";
        RuntimeDirectory = "jupyter-sandbox";
        WorkingDirectory = jupyterStateDir;
        Restart = "on-failure";
        RestartSec = 5;
        DynamicUser = true;
        MemoryMax = "4G";
        TasksMax = 256;
        CapabilityBoundingSet = "";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
      };
    };

    # Start the sandbox before the UI that drives it (best-effort; the UI only
    # connects when the code interpreter is used).
    systemd.services.open-webui.after = [ "jupyter-sandbox.service" ];
  };
}
