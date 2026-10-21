# Cross-machine memory: Graphiti (episodes/entities/edges) over FalkorDB, with
# a local llama.cpp embedder. The MCP origin is loopback-only; the Cloudflare
# Access route and the MCP wrapper land in #217/#218. Everything here is
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
  cfg = config.memory;
  ports = import ../ports.nix;
  inherit (aiProviders) smortress;

  # bge-m3 Q8_0: 1024-d (Graphiti's default EMBEDDING_DIM), 8k context, no
  # query/document prefixes, so the stock OpenAI embedder client works as-is.
  # CPU-only on purpose: the 3090 is committed to the 200K-context chat model,
  # and embeddings are a bulk-ingest cost, not an interactive one.
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
      host: "127.0.0.1"
      port: ${toString cfg.mcpPort}

    llm:
      provider: "openai"
      model: "${smortress.models.qwen38.id}"
      # Deterministic extraction; llama.cpp's own sampling temp is 1.0 and
      # would vary the JSON between identical episodes.
      temperature: 0.0
      max_tokens: 4096
      # llama.cpp accepts JSON mode but not OpenAI's strict json_schema
      # guarantees; Graphiti then injects the schema into the prompt.
      structured_output_mode: "json_object"
      providers:
        openai:
          api_key: "none"
          api_url: "http://127.0.0.1:${toString ports.llm}/v1"

    embedder:
      provider: "openai"
      model: "bge-m3"
      dimensions: 1024
      providers:
        openai:
          api_key: "none"
          api_url: "http://127.0.0.1:${toString cfg.embeddingPort}/v1"

    database:
      provider: "falkordb"
      providers:
        falkordb:
          uri: "redis://127.0.0.1:6379"
          database: "default_db"

    graphiti:
      group_id: "global"
      user_id: "maki"
  '';
in
{
  options.memory = {
    enable = lib.mkEnableOption "the cross-machine memory stack (Graphiti MCP + FalkorDB + local embedder)";

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/memory";
      description = "Root for the graph's persistent state. The episode export joins it in #223.";
    };

    mcpPort = lib.mkOption {
      type = lib.types.port;
      default = ports.memoryMcp;
      description = "Loopback port the Graphiti MCP server listens on. Read from ports.nix so the #217 ingress cannot drift.";
    };

    embeddingPort = lib.mkOption {
      type = lib.types.port;
      default = 8183;
      description = "Loopback port the embedding llama.cpp instance listens on.";
    };

    falkordbImage = lib.mkOption {
      type = lib.types.str;
      default = "falkordb/falkordb-server:v4.22.2";
      description = "Pinned FalkorDB image. FalkorDB is SSPLv1 and not in nixpkgs, so containers are the only route.";
    };

    graphitiImage = lib.mkOption {
      type = lib.types.str;
      # The graphiti-0.31.2 suffix matters: graphiti-core below 0.31.1 fails
      # against FalkorDB 6.x index DDL, and the image's build-arg default is
      # older than its tag suggests.
      default = "zepai/knowledge-graph-mcp:1.1.3-graphiti-0.31.2-standalone";
      description = "Pinned Graphiti MCP image.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.llm.enable;
        message = "memory requires llm.enable: extraction runs on the local chat model at ports.llm.";
      }
    ];

    # The containers share the host network so the MCP server can reach llama.cpp
    # and the embedder on 127.0.0.1 without binding either to a bridge. FalkorDB
    # publishes only to loopback, so nothing here is reachable off-host.
    virtualisation.oci-containers.backend = "podman";

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0700 root root -"
      "d ${cfg.dataDir}/falkordb 0700 root root -"
    ];

    virtualisation.oci-containers.containers = {
      memory-falkordb = {
        serviceName = "memory-falkordb";
        image = cfg.falkordbImage;
        ports = [ "127.0.0.1:6379:6379" ];
        volumes = [ "${cfg.dataDir}/falkordb:/var/lib/falkordb/data" ];
        environment = {
          # Durability over speed: until #223 lands the episode export, this
          # volume is the only copy of the graph (the raw corpus lives in sdlc,
          # git, and session JSONL, but not the extracted entities/facts).
          REDIS_ARGS = "--appendonly yes --appendfsync everysec";
        };
      };

      memory-graphiti-mcp = {
        serviceName = "memory-graphiti-mcp";
        image = cfg.graphitiImage;
        dependsOn = [ "memory-falkordb" ];
        extraOptions = [
          "--network=host"
          # The MCP server ingests untrusted text and drives an LLM. With host
          # networking it shares the host's loopback, so drop every capability
          # and block setuid escalation; root inside is then a plain uid.
          "--cap-drop=ALL"
          "--security-opt=no-new-privileges"
          # The image's healthcheck targets its default port; this instance
          # listens on ports.memoryMcp.
          "--health-cmd=curl -f http://127.0.0.1:${toString cfg.mcpPort}/health >/dev/null || exit 1"
          "--health-interval=10s"
          "--health-timeout=5s"
          "--health-start-period=15s"
        ];
        volumes = [ "${graphitiConfig}:/app/mcp/config/config.yaml:ro" ];
        environment = {
          CONFIG_PATH = "/app/mcp/config/config.yaml";
          # The image sets 0.0.0.0; with host networking that would listen on
          # every interface. Environment wins over the YAML config.
          SERVER__HOST = "127.0.0.1";
          # Used only for empty-query searches; it must match the embedder
          # width or FalkorDB rejects the zero vector.
          EMBEDDING_DIM = "1024";
        };
      };
    };

    # First boot pulls both images over the network, and a transient failure
    # must not leave the stack failed until an operator notices; the default
    # 5-starts-in-10s limit turns a flaky pull into exactly that.
    systemd.services.memory-falkordb = {
      unitConfig.StartLimitIntervalSec = 0;
      serviceConfig = {
        Restart = lib.mkForce "always";
        RestartSec = "10s";
      };
    };

    systemd.services.memory-graphiti-mcp = {
      unitConfig.StartLimitIntervalSec = 0;
      serviceConfig = {
        Restart = lib.mkForce "always";
        RestartSec = "10s";
      };
    };

    # A container start only waits for the unit to be up, not for FalkorDB to
    # answer; Graphiti builds indices on startup and would exit otherwise.
    systemd.services.memory-graphiti-mcp.preStart = ''
      for _ in $(seq 60); do
        ${pkgs.redis}/bin/redis-cli -h 127.0.0.1 -p 6379 ping >/dev/null 2>&1 && exit 0
        sleep 1
      done
      echo "memory-graphiti-mcp: FalkorDB did not become ready in 60s" >&2
      exit 1
    '';

    # A second llama.cpp instance: services.llama-cpp is single-instance, and
    # the chat instance's speculative decoding must not carry embedding flags.
    systemd.services.llama-cpp-embed = {
      description = "llama.cpp embedding server (bge-m3) for the memory stack";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      unitConfig.StartLimitIntervalSec = 0;
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
          "--batch-size"
          "2048"
          "--ubatch-size"
          "2048"
          "--host"
          "127.0.0.1"
          "--port"
          (toString cfg.embeddingPort)
          "--no-webui"
        ];
        Restart = "on-failure";
        RestartSec = 5;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
      };
    };
  };
}
