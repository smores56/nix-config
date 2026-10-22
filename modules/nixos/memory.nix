# Cross-machine memory: Graphiti (episodes/entities/edges) over FalkorDB, with
# Neuralwatt extraction behind a loopback gateway and a configurable embedder
# (local bge-m3 by default). The MCP origin is private: loopback only, reached
# off-host through the Cloudflare Access route. Everything here is
# personal-only: the work machine runs its own Claude workflow and never
# reaches this store.
{
  config,
  lib,
  pkgs,
  aiProviders,
  ...
}:
let
  ports = import ../ports.nix;
  inherit (aiProviders) neuralwatt;
  memoryPackage = import ../features/ai/memory/package.nix { inherit pkgs; };

  # Loopback ports and the data root. The wrapper's port is the only one shared
  # with the tunnel ingress, so it lives in ports.nix; Graphiti and the local
  # services are private to this module.
  dbPort = 6379;
  graphitiPort = 8184;
  embeddingPort = 8183;
  # Graphiti reaches Neuralwatt through this gateway on loopback. It owns the
  # account key and adds `reasoning_effort: "none"` to chat completions, because
  # extraction that reasons spends its whole budget and returns empty content.
  # Deliberately not in ports.nix: only this module (listener plus Graphiti's
  # config) reads it, and it is never tunneled.
  llmProxyPort = 8082;
  # StateDirectory creates /var/lib/<name> for the wrapper; tmpfiles only adds
  # the root-owned FalkorDB subdirectory, so the two never disagree.
  stateDirectory = "memory";
  dataDir = "/var/lib/${stateDirectory}";

  # Work markers come from the shared identity so the wrapper and the shim
  # cannot disagree about what a work repo looks like.
  work = config.user.work;
  workSshMarker = baseNameOf work.sshConfig;

  # Tags alone are re-pushable upstream; the digests make the same commit pull
  # the same bytes on a fresh host or after `podman rmi`.
  # FalkorDB is SSPLv1 and not in nixpkgs, so a container is the only route.
  falkordbImage = "falkordb/falkordb-server:v4.22.2@sha256:103b70949bc9019dd025e62e077665349b73e96add5c45738e73ddf73eef6220";
  # The graphiti-0.31.2 suffix is what the image was built against: below
  # 0.31.0, graphiti-core's index DDL does not work on FalkorDB 6.x, and the
  # image's build-arg default (0.29.1) is older than the tag suggests.
  graphitiImage = "zepai/knowledge-graph-mcp:1.1.3-graphiti-0.31.2-standalone@sha256:288b79e987adc71d1f55f9f44d9a62fb0422a80eb6870b0e32abb9ad85c12d69";

  # Two embedding positions behind one switch. `local` is the shipped default:
  # bge-m3 on llama.cpp, 1024-d, no egress. `neuralwatt` sends the same traffic
  # to qwen3-embedding-8b through the gateway at 4096-d; that model is
  # preview-only and this account currently gets a 404, so the switch is one
  # line once access lands, but it re-embeds the whole corpus at a new width.
  embedders = {
    local = {
      model = "bge-m3";
      dimensions = 1024;
      url = "http://127.0.0.1:${toString embeddingPort}";
      # llama.cpp serves /health on the root, not under /v1.
      readyProbe = "${pkgs.curl}/bin/curl -sf http://127.0.0.1:${toString embeddingPort}/health";
    };
    neuralwatt = {
      model = "qwen3-embedding-8b";
      dimensions = 4096;
      url = "http://127.0.0.1:${toString llmProxyPort}";
      # Nothing behind the gateway answers /health for the embedder, so the
      # only honest probe is a real (one-word) embedding.
      readyProbe = "${pkgs.curl}/bin/curl -sf -X POST http://127.0.0.1:${toString llmProxyPort}/v1/embeddings -H 'content-type: application/json' -d '{\"model\":\"qwen3-embedding-8b\",\"input\":\"ready\"}'";
    };
  };
  embedder = embedders.${config.memory.embedder};
  localEmbedder = config.memory.embedder == "local";

  # bge-m3 Q8_0: 1024-d, 8k context, no query/document prefixes, so the stock
  # OpenAI embedder client works as-is. It backs the default embedder and stays
  # deployed whatever memory.embedder selects, as the fallback if the preview
  # model never becomes available. CPU-only on purpose: the 3090 is committed
  # to the local chat model. Searches embed the query too, but a short bge-m3
  # query is cheap; bulk ingest dominates the cost.
  embedModel = pkgs.fetchurl {
    url = "https://huggingface.co/gpustack/bge-m3-GGUF/resolve/main/bge-m3-Q8_0.gguf";
    hash = "sha256-lQ9Kjl4ZR3ptPCbS8WIjPCAALGAfdeSwAuMjmZeCEWc=";
  };

  # Graphiti reads the LLM and embedder base URLs from one config file (the
  # shipped Docker configs share OPENAI_API_URL for both). Keep them separate:
  # extraction goes to Neuralwatt through the gateway, embeddings to whichever
  # embedder memory.embedder selects.
  graphitiConfig = pkgs.writeText "graphiti-mcp-config.yaml" ''
    server:
      transport: "http"
      port: ${toString graphitiPort}

    llm:
      provider: "openai"
      model: "${neuralwatt.models.deepseekFlash.id}"
      # Deterministic extraction: identical episodes must produce the same graph.
      temperature: 0.0
      # Graphiti's extraction and dedup prompts ask for up to 16k tokens; the
      # MCP default of 4096 truncates a large episode into invalid JSON. An
      # 8000-char section near MAX_SECTION_CHARS still needs more than 8192
      # (measured: generation stopped at 8192 tokens, char ~8320 of the JSON),
      # so match the documented ceiling.
      max_tokens: 16384
      # Grammar-enforced JSON. json_object relies on the model to comply and
      # occasionally yields prose/empty output; the gateway already disables
      # thinking for extraction, and json_schema makes every response parseable.
      structured_output_mode: "json_schema"
      providers:
        openai:
          # graphiti-core requires a non-empty key, so "none" is the
          # placeholder: the gateway replaces exactly that with the real
          # Neuralwatt key. Nothing secret lives in this file or in Graphiti's
          # environment.
          api_key: "none"
          # The gateway, which owns the key and turns thinking off. Calling
          # Neuralwatt directly would spend the extraction budget on reasoning.
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

    # Deliberately generic entity types (graphiti-core defaults); the wrapper
    # can supply curated ones later.
    graphiti:
      group_id: "global"
      user_id: "maki"
  '';
in
{
  options.memory.enable = lib.mkEnableOption "the cross-machine memory stack (Graphiti MCP + FalkorDB + embedder)";

  # Extraction is hosted (Neuralwatt through the gateway), so memory never
  # depends on the local chat model. Embeddings stay switchable: bge-m3 on
  # llama.cpp by default, qwen3-embedding-8b through the same gateway when
  # access is granted.
  options.memory.embedder = lib.mkOption {
    type = lib.types.enum [
      "local"
      "neuralwatt"
    ];
    default = "local";
    description = ''
      Where Graphiti embeds episodes and queries. `local` runs bge-m3 on
      llama.cpp (1024 dimensions, no egress); `neuralwatt` uses
      qwen3-embedding-8b through the memory-llm-proxy (4096 dimensions). The
      local service stays deployed either way, and switching re-embeds the
      corpus at a new width. qwen3-embedding-8b prefers an `Instruct: …` /
      `Query:` prefix on queries that Graphiti's OpenAI embedder does not send,
      so expect a small retrieval penalty.
    '';
  };

  config = lib.mkIf config.memory.enable {
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
              embeddingPort
              llmProxyPort
              ports.memoryMcp
            ]
          ) == 5;
        message = "memory's loopback ports (FalkorDB, Graphiti, embedder, Neuralwatt gateway, ports.memoryMcp) must all differ.";
      }
    ];

    # The containers share the host network so the MCP server can reach llama.cpp
    # and the embedder on 127.0.0.1 without binding either to a bridge. FalkorDB
    # publishes only to loopback, so nothing here is reachable off-host.
    virtualisation.oci-containers.backend = "podman";

    # StateDirectory owns /var/lib/memory for the wrapper (the registry and
    # future export); tmpfiles only creates FalkorDB's root-owned subdirectory
    # because that container runs rootful. Keep the two in one place so they
    # cannot disagree about the path.
    users.groups.memory = { };
    users.users.memory = {
      isSystemUser = true;
      group = "memory";
    };
    # `memory ingest` runs as the human user and authenticates to the wrapper's
    # /internal routes with the token the wrapper writes into the state dir
    # (0640 memory:memory, reachable because the dir is 0750). The tunnel is a
    # raw TCP forward, so the wrapper cannot tell a tunneled client from a local
    # one by peer address; the group alone may read that token.
    users.users.${config.machine.username}.extraGroups = [ "memory" ];

    systemd.tmpfiles.rules = [
      "d ${dataDir}/falkordb 0700 root root -"
    ];

    virtualisation.oci-containers.containers = {
      memory-falkordb = {
        serviceName = "memory-falkordb";
        image = falkordbImage;
        ports = [ "127.0.0.1:${toString dbPort}:6379" ];
        volumes = [ "${dataDir}/falkordb:/var/lib/falkordb/data" ];
        extraOptions = [
          # redis-server needs no capabilities and the data dir is root-owned.
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
          # AOF is the only durability we need; disabling RDB keeps BGSAVE
          # forks from spiking memory on a host with OOM history. Until the
          # episode export lands, this volume is the only copy of the graph.
          REDIS_ARGS = "--appendonly yes --appendfsync everysec --save \"\"";
        };
      };

      memory-graphiti-mcp = {
        serviceName = "memory-graphiti-mcp";
        image = graphitiImage;
        extraOptions = [
          "--network=host"
          # This process ingests untrusted text and drives an LLM. It shares
          # the host's loopback through host networking, so drop capabilities
          # and block setuid escalation. Rootful podman still maps container
          # root to host root: this bounds, but does not isolate, the damage.
          "--cap-drop=ALL"
          "--security-opt=no-new-privileges"
          # The image's built-in healthcheck targets its default port 8000,
          # while this instance listens on graphitiPort. Its transient systemd
          # unit then fails during start and makes `nixos-rebuild switch` report
          # a failed unit. The image's /health is static anyway; the wrapper's
          # preStart is the real readiness gate.
          "--no-healthcheck"
        ];
        volumes = [ "${graphitiConfig}:/app/mcp/config/config.yaml:ro" ];
        environment = {
          # The image sets 0.0.0.0; with host networking that would listen on
          # every interface. Environment wins over the YAML config.
          SERVER__HOST = "127.0.0.1";
          # Used for the zero vector on query-less searches; it must match the
          # embedder width or FalkorDB rejects the vector. Same source as the
          # YAML dimensions above.
          EMBEDDING_DIM = toString embedder.dimensions;
          # Hosted extraction has no local slot to queue behind; four in-flight
          # episodes keep the reconciler busy without hammering the API. With
          # the local embedder those calls queue behind llama-server's single
          # slot, which is fine: embedding calls are far shorter than the chat
          # generations this limit used to protect.
          SEMAPHORE_LIMIT = "4";
        };
      };
    };

    # No dependsOn: that would make a FalkorDB restart stop the MCP and discard
    # its in-memory episode queue. Start after it, and let the preStart probe
    # below wait for readiness.
    # A broken image tag, config, or volume should settle into `failed` and
    # email, not flap forever; 10 starts in an hour is generous for a flaky
    # pull. TimeoutStartSec bounds a hung image pull (the module default is 0).
    systemd.services.memory-falkordb = {
      unitConfig = {
        StartLimitIntervalSec = "1h";
        StartLimitBurst = 10;
      };
      serviceConfig = {
        TimeoutStartSec = lib.mkForce "30m";
        Restart = lib.mkForce "always";
        RestartSec = "10s";
      };
      onFailure = lib.optional config.alerting.enable "cloudflare-email@%n.service";
    };

    systemd.services.memory-graphiti-mcp = {
      wants = [
        "memory-falkordb.service"
        "memory-llm-proxy.service"
      ]
      ++ lib.optional localEmbedder "llama-cpp-embed.service";
      after = [
        "memory-falkordb.service"
        "memory-llm-proxy.service"
      ]
      ++ lib.optional localEmbedder "llama-cpp-embed.service";
      unitConfig = {
        StartLimitIntervalSec = "1h";
        StartLimitBurst = 10;
      };
      serviceConfig = {
        TimeoutStartSec = lib.mkForce "30m";
        Restart = lib.mkForce "always";
        RestartSec = "10s";
      };
      onFailure = lib.optional config.alerting.enable "cloudflare-email@%n.service";
      # A container start only waits for the unit to be up, not for FalkorDB to
      # answer; Graphiti builds indices on startup and would exit otherwise.
      # The embedder is probed too, because every search and ingest needs it.
      # Extraction readiness is deliberately not a gate: reads and embedder
      # traffic do not need it, and the MCP's in-memory write queue can drop an
      # episode while Neuralwatt is unreachable, so the wrapper records the
      # write as pending and its reconciler verifies it later.
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

    # Graphiti's only route to Neuralwatt: this gateway owns the account key
    # (injected from a systemd credential) and adds `reasoning_effort: "none"`
    # to chat completions. graphiti-core cannot ask for that per request, and
    # extraction that reasons returns empty content. Everything else (models,
    # embeddings, health, streaming) is forwarded unchanged, with Graphiti's
    # dummy `Bearer none` replaced by the real key. It is the single egress
    # point, so no other memory process needs the key. Loopback listener, no
    # state.
    systemd.services.memory-llm-proxy = {
      description = "Neuralwatt gateway for Graphiti extraction (key injection, thinking off)";
      wantedBy = [ "multi-user.target" ];
      unitConfig = {
        StartLimitIntervalSec = "1h";
        StartLimitBurst = 10;
      };
      onFailure = lib.optional config.alerting.enable "cloudflare-email@%n.service";
      serviceConfig = {
        DynamicUser = true;
        ExecStart = "${memoryPackage}/bin/memory-llm-proxy";
        Environment = [
          "MEMORY_LLM_UPSTREAM=https://api.neuralwatt.com"
          "MEMORY_LLM_PROXY_HOST=127.0.0.1"
          "MEMORY_LLM_PROXY_PORT=${toString llmProxyPort}"
          # %d is systemd's credential directory. The key reaches the process
          # only as a private file: never the environment, never the Nix store.
          "MEMORY_NEURALWATT_KEY_FILE=%d/neuralwatt-api-key"
        ];
        # systemd reads the sops secret as root and hands the service a copy.
        # A missing key fails the unit instead of starting a gateway that would
        # refuse every request.
        LoadCredential = "neuralwatt-api-key:/run/secrets/neuralwatt-api-key";
        Restart = "always";
        RestartSec = "5s";
        # A streaming relay: buffers are per-connection, requests are tiny.
        MemoryMax = "256M";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        # A loopback listener with public egress: this unit is the memory
        # stack's only off-host route, so no IP filters here.
      };
    };

    # The wrapper is the only memory service the tunnel reaches. It validates
    # the group header the shim sends, refuses work groups, and records writes
    # as pending in the typed registry. A background reconciler proves each
    # write against FalkorDB and resolves it to active or failed. Raw Graphiti
    # stays on the internal graphitiPort and is never tunneled. Because the
    # tunnel delivers every request as loopback, the /internal ingest routes
    # also require a per-start bearer token written into the state dir.
    systemd.services.memory-mcp = {
      description = "memory MCP wrapper (project groups, typed registry, reconciler)";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "memory-graphiti-mcp.service"
        "memory-llm-proxy.service"
      ]
      ++ lib.optional localEmbedder "llama-cpp-embed.service";
      after = [
        "memory-graphiti-mcp.service"
        "memory-llm-proxy.service"
      ]
      ++ lib.optional localEmbedder "llama-cpp-embed.service";
      unitConfig = {
        StartLimitIntervalSec = "1h";
        StartLimitBurst = 10;
      };
      onFailure = lib.optional config.alerting.enable "cloudflare-email@%n.service";
      serviceConfig = {
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
          # Readiness probes the gateway so search and retries can pause when the
          # model endpoint is down; writes are never gated on it.
          "MEMORY_LLM_URL=http://127.0.0.1:${toString llmProxyPort}"
          "MEMORY_EMBED_URL=${embedder.url}"
          "MEMORY_STATE_DIR=${dataDir}"
          # Reconciler cadence: poll pending rows, tolerate a slow extraction,
          # and back off between bounded retries.
          "MEMORY_RECONCILE_INTERVAL=10"
          "MEMORY_RECONCILE_GRACE=600"
          "MEMORY_RECONCILE_BACKOFF=60"
          "MEMORY_WORK_EMAIL=${work.email}"
          "MEMORY_WORK_OWNER_GLOB=${work.githubOwnerGlob}"
          "MEMORY_WORK_FLOW=${work.flow}"
          "MEMORY_WORK_SSH_MARKER=${workSshMarker}"
        ]
        # A remote embedder has no /health behind the gateway; naming its model
        # makes readiness send a one-word embedding instead.
        ++ lib.optional (!localEmbedder) "MEMORY_EMBED_MODEL=${embedder.model}";
        # The pre-start probe bounds how long a stale graph or model endpoint
        # can keep the unit in activation.
        TimeoutStartSec = "2min";
        Restart = "always";
        RestartSec = "5s";
        MemoryMax = "512M";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        # Loopback only: the wrapper talks to Graphiti and the two model
        # endpoints and needs no other network identity.
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

    # A second llama.cpp instance: services.llama-cpp is single-instance, and
    # the chat instance's speculative decoding must not carry embedding flags.
    # nixpkgs' CPU build keeps this independent of the pinned CUDA fork. It
    # backs the default embedder and stays deployed as the fallback.
    systemd.services.llama-cpp-embed = {
      description = "llama.cpp embedding server (bge-m3) for the memory stack";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      unitConfig = {
        StartLimitIntervalSec = "1h";
        StartLimitBurst = 10;
      };
      onFailure = lib.optional config.alerting.enable "cloudflare-email@%n.service";
      serviceConfig = {
        DynamicUser = true;
        StateDirectory = "llama-cpp-embed";
        CacheDirectory = "llama-cpp-embed";
        Environment = "LLAMA_CACHE=/var/cache/llama-cpp-embed";
        ExecStart = lib.escapeShellArgs [
          "${pkgs.llama-cpp}/bin/llama-server"
          "--model"
          "${embedModel}"
          "--alias"
          "bge-m3"
          "--embeddings"
          "--pooling"
          "cls"
          "--ctx-size"
          "8192"
          # A single input longer than the physical batch is rejected outright;
          # match the context so long entity summaries do not fail an episode.
          "--batch-size"
          "8192"
          "--ubatch-size"
          "8192"
          "--host"
          "127.0.0.1"
          "--port"
          (toString embeddingPort)
          "--no-webui"
        ];
        # Bulk ingest must not starve the chat model or trip the OOM killer.
        CPUWeight = 50;
        MemoryMax = "8G";
        Restart = "on-failure";
        RestartSec = 10;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
      };
    };
  };
}
