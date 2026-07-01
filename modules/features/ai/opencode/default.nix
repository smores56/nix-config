{
  config,
  lib,
  aiNeuralwatt,
  ...
}:
let
  workModels = config.dotfiles.workModels;
  activePreset = if workModels then "cloudflare" else "neuralwatt";

  cloudflareProviderId = "cloudflare-workers-ai";
  cloudflareStrongModel = "${cloudflareProviderId}/@cf/zai-org/glm-5.2";
  cloudflareMidModel = "${cloudflareProviderId}/@cf/openai/gpt-oss-120b";
  cloudflareWeakModel = "${cloudflareProviderId}/@cf/zai-org/glm-4.7-flash";

  openaiModel = id: variant: { inherit id variant; };
  openaiStrongModel = openaiModel "openai/gpt-5.5" "xhigh";
  openaiStrongHighModel = openaiModel "openai/gpt-5.5" "xhigh";
  openaiStrongLowModel = openaiModel "openai/gpt-5.5" "low";
  openaiMidModel = openaiModel "openai/gpt-5.4" "medium";
  openaiWeakLowModel = openaiModel "openai/gpt-5.4-mini" "low";
  openaiWeakMediumModel = openaiModel "openai/gpt-5.4-mini" "medium";

  neuralwattStrongModel = "${aiNeuralwatt.providerId}/${aiNeuralwatt.models.glm52.id}";
  neuralwattMidModel = "${aiNeuralwatt.providerId}/${aiNeuralwatt.models.qwen35.id}";
  neuralwattWeakModel = "${aiNeuralwatt.providerId}/${aiNeuralwatt.models.qwen36.id}";

  strongModel = if workModels then cloudflareStrongModel else neuralwattStrongModel;
  midModel = if workModels then cloudflareMidModel else neuralwattMidModel;
  weakModel = if workModels then cloudflareWeakModel else neuralwattWeakModel;

  withBackup = primary: backup: [
    primary
    backup
  ];
  agent = model: skills: mcps: { inherit model skills mcps; };
  orchestratorMcps = [
    "*"
    "!context7"
  ];
  librarianMcps = [
    "websearch"
    "context7"
    "gh_grep"
  ];

  modelAttrs = model: {
    name = model.name;
    limit = {
      context = model.context;
      output = model.output;
    };
  };

  providerConfig =
    if workModels then
      {
        ${cloudflareProviderId}.models = {
          "@cf/zai-org/glm-5.2" = {
            name = "GLM-5.2";
            limit = {
              context = 262144;
              output = 32768;
            };
          };
          "@cf/openai/gpt-oss-120b" = {
            name = "GPT OSS 120B";
            limit = {
              context = 128000;
              output = 32768;
            };
          };
          "@cf/zai-org/glm-4.7-flash" = {
            name = "GLM-4.7 Flash";
            limit = {
              context = 131072;
              output = 16384;
            };
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
          models = lib.mapAttrs' (_: m: lib.nameValuePair m.id (modelAttrs m)) aiNeuralwatt.models;
        };
      };

  cloudflarePreset = {
    orchestrator = agent (withBackup cloudflareStrongModel openaiStrongModel) [ "*" ] orchestratorMcps;
    oracle = agent (withBackup cloudflareStrongModel openaiStrongHighModel) [ "simplify" ] [ ];
    council = agent (withBackup cloudflareMidModel openaiMidModel) [ ] [ ];
    librarian = agent (withBackup cloudflareWeakModel openaiWeakLowModel) [ ] librarianMcps;
    explorer = agent (withBackup cloudflareWeakModel openaiWeakLowModel) [ ] [ ];
    designer = agent (withBackup cloudflareWeakModel openaiWeakMediumModel) [ ] [ ];
    fixer = agent (withBackup cloudflareStrongModel openaiStrongLowModel) [ ] [ ];
  };

  neuralwattPreset = {
    orchestrator = agent neuralwattStrongModel [ "*" ] orchestratorMcps;
    oracle = agent neuralwattStrongModel [ "simplify" ] [ ];
    librarian = agent neuralwattMidModel [ ] librarianMcps;
    explorer = agent neuralwattWeakModel [ ] [ ];
    designer = agent neuralwattWeakModel [ ] [ ];
    fixer = agent neuralwattMidModel [ ] [ ];
  };

  opencodeConfig = {
    "$schema" = "https://opencode.ai/config.json";
    plugin = [ "oh-my-opencode-slim" ];
    model = strongModel;
    small_model = weakModel;
    share = "disabled";
    instructions = [ "AGENTS.md" ];
    lsp = true;
    compaction = {
      auto = true;
      prune = true;
    };
    permission."*" = "allow";
    default_agent = "orchestrator";
    provider = providerConfig;
    agent = {
      explore.disable = true;
      general.disable = true;
    };
  };

  slimConfig = {
    "$schema" = "https://unpkg.com/oh-my-opencode-slim@latest/oh-my-opencode-slim.schema.json";
    preset = activePreset;
    setDefaultAgent = true;
    disabled_agents = [ "observer" ];
    multiplexer = {
      type = "zellij";
      layout = "main-vertical";
    };
    presets.${activePreset} = if workModels then cloudflarePreset else neuralwattPreset;
  }
  // lib.optionalAttrs workModels {
    council = {
      default_preset = activePreset;
      councillor_execution_mode = "serial";
      presets.${activePreset} = {
        architect.model = cloudflareStrongModel;
        implementer.model = cloudflareMidModel;
        skeptic.model = cloudflareWeakModel;
      };
    };
  };

  configJson = lib.generators.toJSON { } opencodeConfig;
  slimConfigJson = lib.generators.toJSON { } slimConfig;
in
{
  config = {
    home.sessionVariables.OPENCODE_EXPERIMENTAL_BACKGROUND_SUBAGENTS = "true";
    home.file.".config/opencode/opencode.jsonc" = {
      force = true;
      text = configJson;
    };
    home.file.".config/opencode/oh-my-opencode-slim.json" = {
      force = true;
      text = slimConfigJson;
    };
  };
}
