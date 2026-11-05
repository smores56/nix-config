# One memory service description, rendered by a runner: `modules/nixos/memory.nix` (systemd and
# rootless podman) or `./darwin.nix` (launchd and Docker Desktop). Image digests, ports,
# container and process environments, the readiness gates and the export arguments live only
# here, so the two runners cannot drift. Runners own supervision, paths, secrets and sandboxing.
#
# A plain function, not a module: it is imported by path like `package.nix`. Environments are
# ordered `[ name value ]` pairs so the NixOS units keep a stable, reviewable order.
{
  lib,
  pkgs,
  memoryPackage,
  ports,
  # `config.user.work`: the employer markers the shim and wrapper classify repos with.
  work,
  # "allow" on the employer's instance, "refuse" everywhere else.
  workPolicy,
  # How a container reaches a service on its host: loopback under host networking, the Docker
  # Desktop alias elsewhere.
  containerHost,
  # What the containers' listeners bind to: Graphiti must listen on every container interface for
  # a published port to reach it, but only on loopback under host networking.
  graphitiListen,
  llm,
  embedder,
}:
let
  dbPort = 6379;
  graphitiPort = 8184;
  proxyPort = ports.memoryLlmProxy;
  hostLocal = "127.0.0.1";

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
  embedderProbe = "${pkgs.curl}/bin/curl -sf -X POST http://${hostLocal}:${toString proxyPort}/v1/embeddings -H 'content-type: application/json' -d '{\"model\":\"${embedder.model}\",\"input\":\"ready\"}'";

  # Separate LLM and embedder URLs; the shipped configs share one.
  graphitiConfig = pkgs.writeText "graphiti-mcp-config.yaml" ''
    server:
      transport: "http"
      port: ${toString graphitiPort}

    llm:
      provider: "openai"
      model: "${llm.model}"
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
          api_url: "http://${containerHost}:${toString proxyPort}/v1"

    embedder:
      provider: "openai"
      model: "${embedder.model}"
      dimensions: ${toString embedder.dimensions}
      providers:
        openai:
          api_key: "none"
          api_url: "http://${containerHost}:${toString proxyPort}/v1"

    database:
      provider: "falkordb"
      providers:
        falkordb:
          uri: "redis://${containerHost}:${toString dbPort}"
          database: "default_db"

    graphiti:
      group_id: "global"
      user_id: "maki"
  '';

  # Redis-CLI/curl probes run on the host, so they always dial loopback.
  health = {
    cmd = "redis-cli ping";
    interval = "10s";
    timeout = "5s";
    startPeriod = "15s";
  };
  # What the shim and the wrapper both need to classify a repo the same way.
  clientEnvironment = [
    [
      "MEMORY_WORK_EMAIL"
      work.email
    ]
    [
      "MEMORY_WORK_OWNER_GLOB"
      (lib.concatStringsSep "," work.githubOwners)
    ]
    [
      "MEMORY_WORK_FLOW"
      work.flow
    ]
    [
      "MEMORY_WORK_POLICY"
      workPolicy
    ]
  ];

in
{
  inherit
    dbPort
    graphitiPort
    proxyPort
    embedder
    clientEnvironment
    graphitiConfig
    reconcileGraceSeconds
    ;
  mcpPort = ports.memoryMcp;

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
            proxyPort
            ports.memoryMcp
          ]
        ) == 4;
      message = "memory's loopback ports (FalkorDB, Graphiti, the LLM gateway, ports.memoryMcp) must all differ.";
    }
  ];

  # Flags both Docker and podman accept; each runner adds its own network and restart flags.
  containers = {
    falkordb = {
      image = falkordbImage;
      hostPort = dbPort;
      containerPort = 6379;
      # `data` is the host directory the runner provides for the graph.
      mountsFor = data: [ "${data}:/var/lib/falkordb/data" ];
      environment = {
        # AOF suffices; no scheduled RDB saves avoids BGSAVE memory spikes. The nightly
        # `memory-export` BGSAVE is the only RDB.
        REDIS_ARGS = "--appendonly yes --appendfsync everysec --save \"\"";
      };
      hardening = [
        # redis-server needs no capabilities.
        "--cap-drop=ALL"
        "--security-opt=no-new-privileges"
      ];
      healthArgs = [
        "--health-cmd=${health.cmd}"
        "--health-interval=${health.interval}"
        "--health-timeout=${health.timeout}"
        "--health-start-period=${health.startPeriod}"
      ];
    };

    graphiti = {
      image = graphitiImage;
      hostPort = graphitiPort;
      containerPort = graphitiPort;
      # `config` is the host path of `graphitiConfig`; a runner whose container engine cannot
      # see the Nix store copies it somewhere shared first.
      mountsFor = config: [ "${config}:/app/mcp/config/config.yaml:ro" ];
      environment = {
        SERVER__HOST = graphitiListen;
        # Zero vector for query-less searches; must match the embedder width.
        EMBEDDING_DIM = toString embedder.dimensions;
        # The gateway's MEMORY_UPSTREAM_CONCURRENCY holds the real ceiling; two here
        # leaves one of a three-slot tier for interactive use. Oversubscribing triggers
        # 429s; lower these first if they return.
        SEMAPHORE_LIMIT = "2";
      };
      hardening = [
        # Ingests untrusted text on the host's loopback: drop capabilities, block setuid.
        "--cap-drop=ALL"
        "--security-opt=no-new-privileges"
      ];
      # The image healthcheck targets port 8000 and fails the unit; the wrapper's
      # readiness gate is the check.
      healthArgs = [ "--no-healthcheck" ];
    };
  };

  # Gate for Graphiti's start: a container start does not wait for FalkorDB, and Graphiti
  # builds indices on startup. Extraction is not a gate: the wrapper records writes as
  # pending and reconciles.
  graphitiReady = ''
    for _ in $(seq 120); do
      ${pkgs.redis}/bin/redis-cli -h ${hostLocal} -p ${toString dbPort} ping >/dev/null 2>&1 \
        && ${embedderProbe} >/dev/null 2>&1 \
        && exit 0
      sleep 1
    done
    echo "memory-graphiti-mcp: FalkorDB or the embedder did not become ready in 120s" >&2
    exit 1
  '';

  wrapperReady = ''
    for _ in $(seq 60); do
      ${pkgs.curl}/bin/curl -sf http://${hostLocal}:${toString graphitiPort}/health >/dev/null 2>&1 \
        && ${embedderProbe} >/dev/null 2>&1 \
        && ${pkgs.curl}/bin/curl -sf http://${hostLocal}:${toString proxyPort}/health >/dev/null 2>&1 \
        && exit 0
      sleep 1
    done
    echo "memory-mcp: Graphiti, the embedder, or the LLM proxy did not become ready in 60s" >&2
    exit 1
  '';

  # The only route off the host for model calls. `keyFile` is the runner's path to the key.
  proxyEnvironment =
    keyFile:
    [
      [
        "MEMORY_LLM_UPSTREAM"
        llm.upstream
      ]
      [
        "MEMORY_LLM_PROXY_HOST"
        hostLocal
      ]
      [
        "MEMORY_LLM_PROXY_PORT"
        (toString proxyPort)
      ]
      [
        "MEMORY_LLM_KEY_FILE"
        keyFile
      ]
    ]
    ++ lib.optional (llm.reasoningEffort != "") [
      "MEMORY_LLM_REASONING_EFFORT"
      llm.reasoningEffort
    ]
    ++ [
      [
        "MEMORY_UPSTREAM_CONCURRENCY"
        (toString llm.concurrency)
      ]
      [
        "MEMORY_UPSTREAM_RETRIES"
        (toString llm.retries)
      ]
    ]
    # Containers dial the proxy by this name, so it must pass the proxy's Host check.
    ++ lib.optional (containerHost != hostLocal) [
      "MEMORY_LLM_PROXY_ALLOWED_HOSTS"
      containerHost
    ]
    ++ lib.optionals (llm.chatBackend == "claude") [
      [
        "MEMORY_LLM_CHAT_BACKEND"
        "claude"
      ]
      [
        "MEMORY_CLAUDE_MODEL"
        llm.model
      ]
      [
        "MEMORY_CLAUDE_BIN"
        llm.claudeBinary
      ]
    ];

  # `stateDir` holds the registry; `extra` is the instance's own pairs (token file, client defaults).
  wrapperEnvironment =
    {
      stateDir,
      extra ? [ ],
    }:
    [
      [
        "MEMORY_MCP_HOST"
        hostLocal
      ]
      [
        "MEMORY_MCP_PORT"
        (toString ports.memoryMcp)
      ]
      [
        "MEMORY_GRAPHITI_URL"
        "http://${hostLocal}:${toString graphitiPort}/mcp"
      ]
      [
        "MEMORY_REDIS_URL"
        "redis://${hostLocal}:${toString dbPort}"
      ]
      # Search and retries pause when the model endpoint is down; writes are never gated.
      [
        "MEMORY_LLM_URL"
        "http://${hostLocal}:${toString proxyPort}"
      ]
      [
        "MEMORY_EMBED_MODEL"
        embedder.model
      ]
      [
        "MEMORY_STATE_DIR"
        stateDir
      ]
      [
        "MEMORY_RECONCILE_INTERVAL"
        "10"
      ]
      # Derived from reconcileGraceSeconds so the two cannot drift.
      [
        "MEMORY_RECONCILE_GRACE"
        (toString reconcileGraceSeconds)
      ]
      [
        "MEMORY_PENDING_STALE_SECONDS"
        (toString reconcileGraceSeconds)
      ]
      [
        "MEMORY_RECONCILE_BACKOFF"
        "60"
      ]
    ]
    ++ clientEnvironment
    ++ extra;

  exportArguments =
    {
      exportDir,
      stateDir,
      graphDir,
      extra ? [ ],
    }:
    [
      "${memoryPackage}/bin/memory-export"
      "export"
      "--root"
      exportDir
      "--state-dir"
      stateDir
      "--graph-url"
      "redis://${hostLocal}:${toString dbPort}"
      "--graph-dir"
      graphDir
      "--graph-timeout"
      "120"
    ]
    ++ extra;

  # `[ name value ]` pairs as an attrset, for runners that take one (launchd).
  toAttrs =
    pairs:
    builtins.listToAttrs (map (p: lib.nameValuePair (builtins.elemAt p 0) (builtins.elemAt p 1)) pairs);
  # ... and as `NAME=value` strings, for systemd's `Environment`.
  toStrings = map (p: "${builtins.elemAt p 0}=${builtins.elemAt p 1}");
}
