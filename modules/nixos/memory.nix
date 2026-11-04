# Personal-only: the work machine never reaches this store. The MCP origin is
# loopback; off-host access goes through the Cloudflare Access route.
{
  config,
  lib,
  pkgs,
  aiProviders,
  ...
}:
let
  hardening = import ../lib/hardening.nix;
  ports = import ../ports.nix;
  inherit (aiProviders) neuralwatt;
  memoryPackage = import ../features/ai/memory/package.nix { inherit pkgs; };

  dbPort = 6379;
  graphitiPort = 8184;
  # Loopback gateway to Neuralwatt, never tunneled. Injects the key and adds
  # `reasoning_effort: "none"` because reasoning extraction returns empty content.
  llmProxyPort = ports.memoryLlmProxy;
  # tmpfiles owns the falkordb subdirectory of the StateDirectory.
  stateDirectory = "memory";
  dataDir = "/var/lib/${stateDirectory}";
  # Pinned so RequiresMountsFor and user@ never see a null uid; matches ids on smortress.
  memoryUid = 982;
  memoryGid = 977;
  # `smores` is the only normal user; revisit if another is added.
  memorySubidStart = 200000;
  # Root-owned, inside the durable tree. A real directory: restic does not follow symlinks.
  exportDir = "/var/lib/data/memory-export";

  # Shared with the shim so both agree on what a work repo is.
  work = config.user.work;

  # A shorter pending-stale window than the reconcile grace re-queues writes that
  # are merely waiting behind a large backfill. 12h covers a day's queue.
  reconcileGraceSeconds = 43200;

  # Digests pin the same bytes on a fresh host. FalkorDB is SSPLv1, not in nixpkgs.
  falkordbImage = "falkordb/falkordb-server:v4.22.2@sha256:103b70949bc9019dd025e62e077665349b73e96add5c45738e73ddf73eef6220";
  # Below graphiti-core 0.31.0 the index DDL fails on FalkorDB 6.x; the image's
  # build-arg default is older than its tag suggests.
  graphitiImage = "zepai/knowledge-graph-mcp:1.1.3-graphiti-0.31.2-standalone@sha256:288b79e987adc71d1f55f9f44d9a62fb0422a80eb6870b0e32abb9ad85c12d69";

  # Changing the model re-embeds the corpus at a new width. Embeddings go through the
  # gateway like extraction; there is no /health behind it, so readiness probes with a
  # real one-word embedding.
  embedder = {
    model = "qwen3-embedding-8b";
    dimensions = 4096;
    url = "http://127.0.0.1:${toString llmProxyPort}";
    readyProbe = "${pkgs.curl}/bin/curl -sf -X POST http://127.0.0.1:${toString llmProxyPort}/v1/embeddings -H 'content-type: application/json' -d '{\"model\":\"qwen3-embedding-8b\",\"input\":\"ready\"}'";
  };

  # Separate LLM and embedder URLs; the shipped configs share one.
  graphitiConfig = pkgs.writeText "graphiti-mcp-config.yaml" ''
    server:
      transport: "http"
      port: ${toString graphitiPort}

    llm:
      provider: "openai"
      model: "${neuralwatt.models.deepseekFlash.id}"
      # Identical episodes must produce the same graph.
      temperature: 0.0
      # Extraction prompts need up to 16k tokens; the MCP default truncates large
      # episodes into invalid JSON.
      max_tokens: 16384
      # json_object occasionally yields prose; json_schema keeps responses parseable.
      structured_output_mode: "json_schema"
      providers:
        openai:
          # graphiti-core requires a non-empty key; the gateway swaps this placeholder.
          api_key: "none"
          # The gateway owns the key and disables thinking.
          api_url: "http://127.0.0.1:${toString llmProxyPort}/v1"

    embedder:
      provider: "openai"
      model: "${embedder.model}"
      dimensions: ${toString embedder.dimensions}
      providers:
        openai:
          api_key: "none"
          api_url: "${embedder.url}/v1"

    database:
      provider: "falkordb"
      providers:
        falkordb:
          uri: "redis://127.0.0.1:${toString dbPort}"
          database: "default_db"

    graphiti:
      group_id: "global"
      user_id: "maki"
  '';
in
{
  config = {
    assertions = [
      {
        assertion = ports.memoryMcp != graphitiPort;
        message = "ports.memoryMcp (the wrapper) and graphitiPort (internal Graphiti) must differ.";
      }
      {
        assertion =
          builtins.length (
            lib.unique [
              dbPort
              graphitiPort
              llmProxyPort
              ports.memoryMcp
            ]
          ) == 4;
        message = "memory's loopback ports (FalkorDB, Graphiti, Neuralwatt gateway, ports.memoryMcp) must all differ.";
      }
    ];

    # Host networking lets the MCP server reach the gateway on 127.0.0.1; FalkorDB
    # publishes to loopback only. Both run rootless as `memory`.
    virtualisation.oci-containers.backend = "podman";

    users.groups.memory = {
      gid = memoryGid;
    };
    users.users.memory = {
      isSystemUser = true;
      uid = memoryUid;
      group = "memory";
      home = dataDir;
      createHome = true;
      # The human user must keep group access to the wrapper token and registry.
      homeMode = "0750";
      linger = true;
      subUidRanges = [
        {
          startUid = memorySubidStart;
          count = 65536;
        }
      ];
      subGidRanges = [
        {
          startGid = memorySubidStart;
          count = 65536;
        }
      ];
    };
    # The MCP token is root:memory 0440 (secrets-common.nix); the operator reads it via group.
    users.users.${config.machine.username}.extraGroups = [ "memory" ];

    systemd.tmpfiles.rules = [
      "d ${dataDir}/falkordb 0700 memory memory -"
      "d ${exportDir} 0700 root root -"
    ];

    # sudo resolves commands on root's secure_path, so `sudo memory restore` needs
    # the system profile.
    environment.systemPackages = [ memoryPackage ];

    virtualisation.oci-containers.containers = {
      memory-falkordb = {
        serviceName = "memory-falkordb";
        image = falkordbImage;
        podman.user = "memory";
        ports = [ "127.0.0.1:${toString dbPort}:6379" ];
        volumes = [ "${dataDir}/falkordb:/var/lib/falkordb/data" ];
        extraOptions = [
          # redis-server needs no capabilities.
          "--cap-drop=ALL"
          "--security-opt=no-new-privileges"
          "--health-cmd=redis-cli ping"
          "--health-interval=10s"
          "--health-timeout=5s"
          "--health-start-period=15s"
          # A hung database must exit so the unit's Restart can act on it.
          "--health-on-failure=kill"
        ];
        environment = {
          # AOF suffices; no scheduled RDB saves avoids BGSAVE memory spikes. The nightly
          # `memory-export` BGSAVE is the only RDB.
          REDIS_ARGS = "--appendonly yes --appendfsync everysec --save \"\"";
        };
      };

      memory-graphiti-mcp = {
        serviceName = "memory-graphiti-mcp";
        image = graphitiImage;
        podman.user = "memory";
        extraOptions = [
          "--network=host"
          # Ingests untrusted text on the host's loopback: drop capabilities, block setuid.
          "--cap-drop=ALL"
          "--security-opt=no-new-privileges"
          # The image healthcheck targets port 8000 and fails the transient unit; the
          # wrapper's preStart is the readiness gate.
          "--no-healthcheck"
        ];
        volumes = [ "${graphitiConfig}:/app/mcp/config/config.yaml:ro" ];
        environment = {
          # The image's 0.0.0.0 would listen everywhere under host networking.
          SERVER__HOST = "127.0.0.1";
          # Zero vector for query-less searches; must match the embedder width.
          EMBEDDING_DIM = toString embedder.dimensions;
          # The gateway's MEMORY_UPSTREAM_CONCURRENCY=2 holds the real ceiling; two here
          # leaves one of the tier's three slots for Maki. Oversubscribing triggers 429s;
          # lower these first if they return.
          SEMAPHORE_LIMIT = "2";
        };
      };
    };

    # No dependsOn: a FalkorDB restart would stop the MCP and drop its episode queue.
    # Ten starts per hour then `failed` + email; TimeoutStartSec bounds a hung pull.
    systemd.services.memory-falkordb = {
      # linger-users only enables lingering; require the user manager for cgroups and
      # XDG_RUNTIME_DIR.
      requires = [
        "user-runtime-dir@${toString memoryUid}.service"
        "user@${toString memoryUid}.service"
      ];
      after = [
        "user-runtime-dir@${toString memoryUid}.service"
        "user@${toString memoryUid}.service"
      ];
      environment.XDG_RUNTIME_DIR = "/run/user/${toString memoryUid}";
      unitConfig = {
        StartLimitIntervalSec = "1h";
        StartLimitBurst = 10;
      };
      serviceConfig = {
        TimeoutStartSec = lib.mkForce "30m";
        Restart = lib.mkForce "always";
        RestartSec = "10s";
      };
      onFailure = [ "cloudflare-email@%n.service" ];
    };

    systemd.services.memory-graphiti-mcp = {
      requires = [
        "user-runtime-dir@${toString memoryUid}.service"
        "user@${toString memoryUid}.service"
      ];
      environment.XDG_RUNTIME_DIR = "/run/user/${toString memoryUid}";
      wants = [
        "memory-falkordb.service"
        "memory-llm-proxy.service"
      ];
      after = [
        "user-runtime-dir@${toString memoryUid}.service"
        "user@${toString memoryUid}.service"
        "memory-falkordb.service"
        "memory-llm-proxy.service"
      ];
      unitConfig = {
        StartLimitIntervalSec = "1h";
        StartLimitBurst = 10;
      };
      serviceConfig = {
        TimeoutStartSec = lib.mkForce "30m";
        Restart = lib.mkForce "always";
        RestartSec = "10s";
      };
      onFailure = [ "cloudflare-email@%n.service" ];
      # A container start does not wait for FalkorDB; Graphiti builds indices on startup.
      # Extraction is not a gate: the wrapper records writes as pending and reconciles.
      preStart = ''
        for _ in $(seq 120); do
          ${pkgs.redis}/bin/redis-cli -h 127.0.0.1 -p ${toString dbPort} ping >/dev/null 2>&1 \
            && ${embedder.readyProbe} >/dev/null 2>&1 \
            && exit 0
          sleep 1
        done
        echo "memory-graphiti-mcp: FalkorDB or the embedder did not become ready in 120s" >&2
        exit 1
      '';
    };

    # Sole route to Neuralwatt: holds the key and adds `reasoning_effort: "none"`
    # (graphiti-core cannot per request); forwards the rest, replacing the dummy
    # `Bearer none`. Fails to start without the key.
    systemd.services.memory-llm-proxy = {
      description = "Neuralwatt gateway for Graphiti extraction (key injection, thinking off)";
      wantedBy = [ "multi-user.target" ];
      unitConfig = {
        StartLimitIntervalSec = "1h";
        StartLimitBurst = 10;
      };
      onFailure = [ "cloudflare-email@%n.service" ];
      serviceConfig = hardening // {
        DynamicUser = true;
        ExecStart = "${memoryPackage}/bin/memory-llm-proxy";
        Environment = [
          "MEMORY_LLM_UPSTREAM=https://api.neuralwatt.com"
          "MEMORY_LLM_PROXY_HOST=127.0.0.1"
          "MEMORY_LLM_PROXY_PORT=${toString llmProxyPort}"
          # %d is systemd's credential directory: the key never enters the environment or store.
          "MEMORY_NEURALWATT_KEY_FILE=%d/neuralwatt-api-key"
          # Two of the tier's three slots; six attempts absorb 429/503 bursts.
          "MEMORY_UPSTREAM_CONCURRENCY=2"
          "MEMORY_UPSTREAM_RETRIES=6"
        ];
        # A missing key fails the unit instead of serving unauthenticated calls.
        LoadCredential = "neuralwatt-api-key:/run/secrets/neuralwatt-api-key";
        Restart = "always";
        RestartSec = "5s";
        # Streaming relay with tiny requests.
        MemoryMax = "256M";
        PrivateDevices = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        # Sole off-host route of the memory stack, so no IP filters.
      };
    };

    # The only service the tunnel reaches. A raw TCP tunnel presents every client as
    # loopback, so each request needs the bearer token (/run/secrets/memory-mcp-token,
    # the wrapper's default path); /health is exempt. A missing secret fails closed (503).
    # Raw Graphiti is never tunneled.
    systemd.services.memory-mcp = {
      description = "memory MCP wrapper (project groups, typed registry, reconciler)";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "memory-graphiti-mcp.service"
        "memory-llm-proxy.service"
      ];
      after = [
        "memory-graphiti-mcp.service"
        "memory-llm-proxy.service"
      ];
      unitConfig = {
        StartLimitIntervalSec = "1h";
        StartLimitBurst = 10;
      };
      onFailure = [ "cloudflare-email@%n.service" ];
      serviceConfig = hardening // {
        User = "memory";
        Group = "memory";
        ExecStart = "${memoryPackage}/bin/memory-mcp";
        WorkingDirectory = dataDir;
        StateDirectory = stateDirectory;
        StateDirectoryMode = "0750";
        Environment = [
          "MEMORY_MCP_HOST=127.0.0.1"
          "MEMORY_MCP_PORT=${toString ports.memoryMcp}"
          "MEMORY_GRAPHITI_URL=http://127.0.0.1:${toString graphitiPort}/mcp"
          "MEMORY_REDIS_URL=redis://127.0.0.1:${toString dbPort}"
          # Search and retries pause when the model endpoint is down; writes are never gated.
          "MEMORY_LLM_URL=http://127.0.0.1:${toString llmProxyPort}"
          "MEMORY_STATE_DIR=${dataDir}"
          "MEMORY_RECONCILE_INTERVAL=10"
          # Derived from reconcileGraceSeconds so the two cannot drift.
          "MEMORY_RECONCILE_GRACE=${toString reconcileGraceSeconds}"
          "MEMORY_PENDING_STALE_SECONDS=${toString reconcileGraceSeconds}"
          "MEMORY_RECONCILE_BACKOFF=60"
          "MEMORY_WORK_EMAIL=${work.email}"
          "MEMORY_WORK_OWNER_GLOB=${lib.concatStringsSep "," work.githubOwners}"
          "MEMORY_WORK_FLOW=${work.flow}"
          # Open WebUI's MCP client cannot send X-Memory-* headers; pin it to the shared
          # group. Header-sending clients keep the strict contract.
          "MEMORY_MCP_DEFAULT_GROUP=global"
          "MEMORY_MCP_DEFAULT_CWD=/chat"
          "MEMORY_MCP_DEFAULT_ACTOR=open-webui"
        ];
        # Bounds how long the pre-start probe can hold activation.
        TimeoutStartSec = "2min";
        Restart = "always";
        RestartSec = "5s";
        MemoryMax = "512M";
        PrivateDevices = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        # Loopback only; rootless port forwarding presents FalkorDB there.
        IPAddressAllow = "localhost";
        IPAddressDeny = "any";
      };
      preStart = ''
        for _ in $(seq 60); do
          ${pkgs.curl}/bin/curl -sf http://127.0.0.1:${toString graphitiPort}/health >/dev/null 2>&1 \
            && ${embedder.readyProbe} >/dev/null 2>&1 \
            && ${pkgs.curl}/bin/curl -sf http://127.0.0.1:${toString llmProxyPort}/health >/dev/null 2>&1 \
            && exit 0
          sleep 1
        done
        echo "memory-mcp: Graphiti, the embedder, or the LLM proxy did not become ready in 60s" >&2
        exit 1
      '';
    };

    # Overwrites registry.sqlite, episodes.jsonl and graph.rdb in exportDir; restic keeps the
    # history. The graph is a derived index, so its BGSAVE is best-effort but a missing graph
    # exits non-zero to trigger the alert. Root reads the memory-owned graph dir. Refuses to
    # run during a restore (.restore-in-progress).
    systemd.services.memory-export = {
      description = "Export the memory registry and snapshot the graph";
      # No dependency on the wrapper: exporting while services are down is the point.
      # `after` only orders runs in one transaction.
      after = [ "memory-mcp.service" ];
      # A restic run that starts mid-export must wait, so a snapshot never captures a half-written set.
      before = [
        "restic-backups-r2.service"
        "restic-backups-local.service"
      ];
      unitConfig = {
        StartLimitIntervalSec = "1h";
        StartLimitBurst = 3;
      };
      onFailure = [ "cloudflare-email@%n.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.escapeShellArgs [
          "${memoryPackage}/bin/memory-export"
          "export"
          "--root"
          exportDir
          "--state-dir"
          dataDir
          "--graph-url"
          "redis://127.0.0.1:${toString dbPort}"
          "--graph-dir"
          "${dataDir}/falkordb"
          "--graph-timeout"
          "120"
        ];
        # A copy must never compete with the store it copies.
        Nice = 19;
        CPUWeight = 20;
        IOSchedulingClass = "idle";
        TimeoutStartSec = "30min";
        TimeoutStopSec = "30min";
        # Keeps /var writable (export and graph live there).
        ProtectSystem = "full";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
        ];
        # Rootless port forwarding presents FalkorDB on localhost.
        IPAddressAllow = "localhost";
        IPAddressDeny = "any";
      };
    };

    systemd.timers.memory-export = {
      description = "Nightly memory registry export";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
        # Spread away from midnight and the backup timers.
        RandomizedDelaySec = "1h";
        Unit = "memory-export.service";
      };
    };
  };
}
