{
  config,
  lib,
  aiNeuralwatt,
  ...
}:
let
  workModels = config.dotfiles.workModels;
  cloudflareWorkersAiEnabled = config.dotfiles.maki.cloudflareWorkersAi.enable;
  cloudflareGlm52 = "cloudflare-workers-ai/@cf/zai-org/glm-5.2";

  # Three-tier model hierarchy mirroring oh-my-pi and maki. Work hosts use
  # Cloudflare Workers AI when enabled; otherwise Codex-backed OpenAI tiers.
  # Personal hosts use Neuralwatt GLM-5.2 / Qwen3.5-397B / Qwen3.6-35B.
  # GLM-5.2 is the primary model (matches maki's roles.default and oh-my-pi's
  # strongModel).
  strongModel =
    if workModels && cloudflareWorkersAiEnabled then
      cloudflareGlm52
    else if workModels then
      "openai/gpt-5.5"
    else
      "${aiNeuralwatt.providerId}/${aiNeuralwatt.models.glm52.id}";
  midModel =
    if workModels && cloudflareWorkersAiEnabled then
      cloudflareGlm52
    else if workModels then
      "openai/gpt-5.4"
    else
      "${aiNeuralwatt.providerId}/${aiNeuralwatt.models.qwen35.id}";
  weakModel =
    if workModels && cloudflareWorkersAiEnabled then
      cloudflareGlm52
    else if workModels then
      "openai/gpt-5.4-mini"
    else
      "${aiNeuralwatt.providerId}/${aiNeuralwatt.models.qwen36.id}";

  # OpenCode's `provider.<id>.models` map is keyed by the model ID string
  # (what appears after the `/` in `model:` refs and in the /models picker).
  # lib.mapAttrs' over `aiNeuralwatt.models` re-keys with the real model.id.
  modelAttrs = model: {
    name = model.name;
    limit = {
      context = model.context;
      output = model.output;
    };
  };

  nwModels = lib.mapAttrs' (_: m: lib.nameValuePair m.id (modelAttrs m)) aiNeuralwatt.models;

  providerConfig =
    if workModels then
      lib.optionalAttrs cloudflareWorkersAiEnabled {
        cloudflare-workers-ai.models."@cf/zai-org/glm-5.2" = {
          name = "GLM-5.2";
          limit = {
            context = 262144;
            output = 262144;
          };
        };
      }
    else
      {
        ${aiNeuralwatt.providerId} = {
          name = "Neuralwatt";
          npm = "@ai-sdk/openai-compatible";
          options = {
            baseURL = aiNeuralwatt.baseUrl;
            apiKey = "{env:NEURALWATT_API_KEY}";
          };
          models = nwModels;
        };
      };

  # Mirror of oh-my-pi's ompConfig: three-tier agents with strong on plan/
  # oracle, medium on build/fixer/librarian, weak on explorer. small_model
  # offloads titles/summaries to the weak tier. Work hosts use OpenCode's
  # built-in providers.
  opencodeConfig = {
    "$schema" = "https://opencode.ai/config.json";
    model = strongModel;
    small_model = weakModel;
    share = "disabled";
    instructions = [ "AGENTS.md" ];
    compaction = {
      auto = true;
      prune = true;
    };
    permission = {
      edit = "ask";
      bash = "ask";
    };
    default_agent = "plan";
    provider = providerConfig;
    agent = {
      build = {
        mode = "primary";
        model = midModel;
        permission = {
          edit = "allow";
          bash = "allow";
        };
      };
      plan = {
        mode = "primary";
        model = strongModel;
        description = "Verify-first research and planning. Read-only by default.";
        permission = {
          edit = "deny";
          bash = {
            "*" = "ask";
            "git status*" = "allow";
            "gh *" = "allow";
            "grep *" = "allow";
          };
        };
      };
      oracle = {
        mode = "subagent";
        model = strongModel;
        description = "Deep review and architecture audit. Read-only.";
        permission = {
          edit = "deny";
          bash = "deny";
        };
      };
      librarian = {
        mode = "subagent";
        model = midModel;
        description = "Docs and web lookup, retrieval, summarization.";
        permission = {
          edit = "deny";
          bash = "deny";
        };
      };
      explorer = {
        mode = "subagent";
        model = weakModel;
        description = "Read-only codebase scout. Fast grep/glob/read.";
        permission = {
          edit = "deny";
          bash = "deny";
        };
      };
      fixer = {
        mode = "subagent";
        model = midModel;
        description = "Scoped implementation tasks.";
        permission = {
          edit = "allow";
          bash = "allow";
        };
      };
    };
  };

  configJson = (lib.generators.toJSON { }) opencodeConfig;
in
{
  # Always-on like maki/oh-my-pi; branches internally on workModels. Work
  # hosts get a minimal config (OpenAI built-in provider) but no Neuralwatt
  # provider — they configure Codex-backed OpenAI separately.
  # OpenCode itself is installed out-of-band (npm/curl installer) so it can
  # self-update via `opencode upgrade`; the nixpkgs package lags too far.
  config = {
    # opencode.jsonc is regular JSONC (the schema validates comments-out).
    # Managed as a Nix home.file symlink into the store: the config is fully
    # derived, no runtime mutability needed (unlike oh-my-pi's config.yml
    # which omp rewrites in-place). Force-overwrites the existing untracked
    # file at ~/.config/opencode/opencode.jsonc.
    home.file.".config/opencode/opencode.jsonc" = {
      force = true;
      text = configJson;
    };
  };
}
