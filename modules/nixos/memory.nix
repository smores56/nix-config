# Cross-machine memory: Graphiti (episodes/entities/edges) over FalkorDB, with
# a local llama.cpp embedder. The MCP origin is private: loopback only, reached
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
  inherit (aiProviders) smortress;
  memoryPackage = import ../features/ai/memory/package.nix { inherit pkgs; };

  # Loopback ports and the data root. The wrapper's port and the embedder's
  # port are shared (tunnel ingress and LobeChat's knowledge base) and live in
  # ports.nix; Graphiti and the local services are private to this module.
  dbPort = 6379;
  graphitiPort = 8184;
  embeddingPort = ports.memoryEmbed;
  # Graphiti reaches the chat model through a thinkless proxy on this port.
  # Extraction must not generate reasoning (it spends the whole budget and
  # returns empty content), while Maki keeps talking to ports.llm directly so
  # interactive answers keep thinking. Deliberately not in ports.nix: only this
  # module (listener plus Graphiti's config) reads it, and it is never tunneled.
  llmProxyPort = 8082;
  # StateDirectory creates /var/lib/<name> for the wrapper; tmpfiles only adds
  # the root-owned FalkorDB subdirectory, so the two never disagree.
  stateDirectory = "memory";
  dataDir = "/var/lib/${stateDirectory}";
  embeddingDim = 1024;

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

  # bge-m3 Q8_0: 1024-d, 8k context, no query/document prefixes, so the stock
  # OpenAI embedder client works as-is. CPU-only on purpose: the 3090 is
  # committed to the 200K-context chat model. Searches embed the query too, but
  # a short bge-m3 query is cheap; bulk ingest dominates the cost.
  embedModel = pkgs.fetchurl {
    url = "https://huggingface.co/gpustack/bge-m3-GGUF/resolve/main/bge-m3-Q8_0.gguf";
    hash = "sha256-lQ9Kjl4ZR3ptPCbS8WIjPCAALGAfdeSwAuMjmZeCEWc=";
  };

  # Graphiti reads the LLM and embedder base URLs from one config file (the
  # shipped Docker configs share OPENAI_API_URL for both). Keep them separate:
  # extraction goes to the big chat model, embeddings to the small embedder.
  graphitiConfig = pkgs.writeText "graphiti-mcp-config.yaml" ''
    server:
      transport: "http"
      port: ${toString graphitiPort}

    llm:
      provider: "openai"
      model: "${smortress.models.qwen38.id}"
      # Deterministic extraction; llama.cpp's own sampling temp is 1.0 and
      # would vary the JSON between identical episodes.
      temperature: 0.0
      # Graphiti's extraction and dedup prompts ask for up to 16k tokens; the
      # MCP default of 4096 truncates a large episode into invalid JSON.
      max_tokens: 8192
      # Grammar-enforced JSON. json_object relies on the model to comply and
      # occasionally yields prose/empty output; the proxy already disables
      # thinking for extraction, and json_schema makes every response parseable.
      structured_output_mode: "json_schema"
      providers:
        openai:
          api_key: "none"
          # The thinkless proxy, not ports.llm: graphiti-core's OpenAI client
          # sends no reasoning control, and the chat server defaults to
          # thinking on.
          api_url: "http://127.0.0.1:${toString llmProxyPort}/v1"

    embedder:
      provider: "openai"
      model: "bge-m3"
      dimensions: ${toString embeddingDim}
      providers:
        openai:
          api_key: "none"
          api_url: "http://127.0.0.1:${toString embeddingPort}/v1"

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
  options.memory.enable = lib.mkEnableOption "the cross-machine memory stack (Graphiti MCP + FalkorDB + local embedder)";

  config = lib.mkIf config.memory.enable {
    assertions = [
      {
        assertion = config.llm.enable;
        message = "memory requires llm.enable: extraction runs on the local chat model at ports.llm.";
      }
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
              ports.llm
              ports.memoryMcp
            ]
          ) == 6;
        message = "memory's loopback ports (FalkorDB, Graphiti, embedder, LLM proxy, ports.llm, ports.memoryMcp) must all differ.";
      }
    ];

    # The containers share the host network so the MCP server can reach llama.cpp
    # and the embedder on 127.0.0.1 without binding either to a bridge. FalkorDB
    # publishes only to loopback, so nothing here is reachable off-host.
    virtualisation.oci-containers.backend = "podman";

    # StateDirectory owns /var/lib/memory for the wrapper (index, audit, future
    # export); tmpfiles only creates FalkorDB's root-owned subdirectory because
    # that container runs rootful. Keep the two in one place so they cannot
    # disagree about the path.
    users.groups.memory = { };
    users.users.memory = {
      isSystemUser = true;
      group = "memory";
    };

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
          EMBEDDING_DIM = toString embeddingDim;
          # The chat server runs a single slot; more in-flight Graphiti calls
          # only queue behind it and risk client timeouts.
          SEMAPHORE_LIMIT = "1";
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
        "llama-cpp-embed.service"
        "memory-llm-proxy.service"
      ];
      after = [
        "memory-falkordb.service"
        "llama-cpp-embed.service"
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
      onFailure = lib.optional config.alerting.enable "cloudflare-email@%n.service";
      # A container start only waits for the unit to be up, not for FalkorDB to
      # answer; Graphiti builds indices on startup and would exit otherwise.
      # The embedder is probed too, because every search and ingest needs it.
      # The chat model is deliberately not a gate: reads do not need it, and
      # the MCP's in-memory write queue can drop an episode while it loads — the
      # wrapper must gate writes on model readiness.
      preStart = ''
        for _ in $(seq 120); do
          ${pkgs.redis}/bin/redis-cli -h 127.0.0.1 -p ${toString dbPort} ping >/dev/null 2>&1 \
            && ${pkgs.curl}/bin/curl -sf http://127.0.0.1:${toString embeddingPort}/health >/dev/null 2>&1 \
            && exit 0
          sleep 1
        done
        echo "memory-graphiti-mcp: FalkorDB or the embedder did not become ready in 120s" >&2
        exit 1
      '';
    };

    # Graphiti's only chat-model route. llama.cpp defaults to thinking, and
    # graphiti-core cannot ask for reasoning_effort per request; this adds
    # `reasoning_effort: "none"` to chat completions and forwards everything
    # else (models, health, streaming) unchanged. Maki still calls ports.llm
    # directly, so its thinking is untouched. Loopback only, no state.
    systemd.services.memory-llm-proxy = {
      description = "thinkless OpenAI-compatible proxy for Graphiti extraction";
      wantedBy = [ "multi-user.target" ];
      wants = [ "llama-cpp.service" ];
      after = [ "llama-cpp.service" ];
      unitConfig = {
        StartLimitIntervalSec = "1h";
        StartLimitBurst = 10;
      };
      onFailure = lib.optional config.alerting.enable "cloudflare-email@%n.service";
      serviceConfig = {
        DynamicUser = true;
        ExecStart = "${memoryPackage}/bin/memory-llm-proxy";
        Environment = [
          "MEMORY_LLM_UPSTREAM=http://127.0.0.1:${toString ports.llm}"
          "MEMORY_LLM_PROXY_HOST=127.0.0.1"
          "MEMORY_LLM_PROXY_PORT=${toString llmProxyPort}"
        ];
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
        ];
        IPAddressAllow = "localhost";
        IPAddressDeny = "any";
      };
    };

    # The wrapper is the only memory service the tunnel reaches. It validates
    # the group header the shim sends, refuses work groups, dedupes writes, and
    # gates them on the local models before Graphiti's in-memory queue can drop
    # them. Raw Graphiti stays on the internal graphitiPort and is never tunneled.
    systemd.services.memory-mcp = {
      description = "memory MCP wrapper (project groups, dedup, provenance)";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "memory-graphiti-mcp.service"
        "llama-cpp-embed.service"
        "memory-llm-proxy.service"
      ];
      after = [
        "memory-graphiti-mcp.service"
        "llama-cpp-embed.service"
        "memory-llm-proxy.service"
      ];
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
          # Readiness probes the proxy, not the chat model, so a dead proxy
          # fails writes instead of letting Graphiti drop an episode.
          "MEMORY_LLM_URL=http://127.0.0.1:${toString llmProxyPort}"
          "MEMORY_EMBED_URL=http://127.0.0.1:${toString embeddingPort}"
          "MEMORY_STATE_DIR=${dataDir}"
          "MEMORY_WORK_EMAIL=${work.email}"
          "MEMORY_WORK_OWNER_GLOB=${work.githubOwnerGlob}"
          "MEMORY_WORK_FLOW=${work.flow}"
          "MEMORY_WORK_SSH_MARKER=${workSshMarker}"
        ];
        # The pre-start probe bounds how long a stale graph or embedder can
        # keep the unit in activation.
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
            && ${pkgs.curl}/bin/curl -sf http://127.0.0.1:${toString embeddingPort}/health >/dev/null 2>&1 \
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
    # nixpkgs' CPU build keeps this independent of the pinned CUDA fork.
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
