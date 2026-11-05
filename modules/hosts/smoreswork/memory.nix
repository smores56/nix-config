# The work Mac's memory instance: Graphiti and FalkorDB in Docker Desktop, extraction through
# headless Claude Code on the subscription (no Anthropic key exists), embeddings through the
# employer's OpenAI key, work repos accepted. The store is local to this machine.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  ports = import ../../ports.nix;
  memoryPackage = import ../../features/ai/memory/package.nix { inherit pkgs; };

  # The model for both Graphiti's requests and `claude -p`; claude is installed outside Nix.
  claudeModel = "claude-haiku-5-5";
  claudeBinary = "${config.home.homeDirectory}/.local/bin/claude";

  service = import ../../features/ai/memory/service.nix {
    inherit
      lib
      pkgs
      memoryPackage
      ports
      ;
    work = config.user.work;
    workPolicy = if config.user.aiProfile == "work" then "allow" else "refuse";
    # Docker Desktop shares no host network: containers publish on loopback and call back out.
    containerHost = "host.docker.internal";
    graphitiListen = "0.0.0.0";
    llm = {
      model = claudeModel;
      # Embeddings and the model list; chat never leaves the machine except through claude.
      upstream = "https://api.openai.com";
      # `claude -p` has no reasoning knob to rewrite.
      reasoningEffort = "";
      chatBackend = "claude";
      inherit claudeBinary;
      concurrency = 2;
      retries = 6;
    };
    # Changing the model or width re-embeds the corpus: wipe the graph and replay it.
    embedder = {
      model = "text-embedding-3-small";
      dimensions = 1536;
    };
  };
in
import ../../features/ai/memory/darwin.nix {
  inherit
    lib
    pkgs
    config
    service
    memoryPackage
    ;
  keyFile = config.sops.secrets.openai-api-key.path;
}
