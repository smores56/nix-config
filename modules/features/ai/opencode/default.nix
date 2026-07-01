{
  config,
  lib,
  aiNeuralwatt,
  ...
}:
let
  workModels = config.dotfiles.workModels;
  cloudflareProviderId = "cloudflare-workers-ai";
  cloudflareStrongModel = "${cloudflareProviderId}/@cf/zai-org/glm-5.2";
  cloudflareMidModel = "${cloudflareProviderId}/@cf/openai/gpt-oss-120b";
  cloudflareWeakModel = "${cloudflareProviderId}/@cf/zai-org/glm-4.7-flash";
  openaiStrongModel = "openai/gpt-5.5";
  openaiMidModel = "openai/gpt-5.4";
  openaiWeakModel = "openai/gpt-5.4-mini";

  strongModel =
    if workModels then
      cloudflareStrongModel
    else
      "${aiNeuralwatt.providerId}/${aiNeuralwatt.models.glm52.id}";
  midModel =
    if workModels then
      cloudflareMidModel
    else
      "${aiNeuralwatt.providerId}/${aiNeuralwatt.models.qwen35.id}";
  weakModel =
    if workModels then
      cloudflareWeakModel
    else
      "${aiNeuralwatt.providerId}/${aiNeuralwatt.models.qwen36.id}";

  openaiModel = id: variant: { inherit id variant; };
  fallbackModel = primary: backup: [
    primary
    backup
  ];

  modelAttrs = model: {
    name = model.name;
    limit = {
      context = model.context;
      output = model.output;
    };
  };

  nwModels = lib.mapAttrs' (_: m: lib.nameValuePair m.id (modelAttrs m)) aiNeuralwatt.models;

  cloudflareModels = {
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

  providerConfig =
    if workModels then
      {
        ${cloudflareProviderId}.models = cloudflareModels;
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
    permission = {
      edit = "ask";
      bash = "ask";
    };
    default_agent = "orchestrator";
    provider = providerConfig;
    agent = {
      explore.disable = true;
      general.disable = true;
    };
  };

  slimConfig = {
    "$schema" = "https://unpkg.com/oh-my-opencode-slim@latest/oh-my-opencode-slim.schema.json";
    preset = if workModels then "cloudflare" else "neuralwatt";
    setDefaultAgent = true;
    autoUpdate = false;
    disabled_agents = [ "observer" ];
    multiplexer = {
      type = "none";
      layout = "main-vertical";
    };
    presets = {
      cloudflare = {
        orchestrator = {
          model = fallbackModel strongModel (openaiModel openaiStrongModel "medium");
          skills = [ "*" ];
          mcps = [
            "*"
            "!context7"
          ];
        };
        oracle = {
          model = fallbackModel strongModel (openaiModel openaiStrongModel "high");
          skills = [ "simplify" ];
          mcps = [ ];
        };
        council = {
          model = fallbackModel midModel (openaiModel openaiMidModel "medium");
          skills = [ ];
          mcps = [ ];
        };
        librarian = {
          model = fallbackModel weakModel (openaiModel openaiWeakModel "low");
          skills = [ ];
          mcps = [
            "websearch"
            "context7"
            "gh_grep"
          ];
        };
        explorer = {
          model = fallbackModel weakModel (openaiModel openaiWeakModel "low");
          skills = [ ];
          mcps = [ ];
        };
        designer = {
          model = fallbackModel weakModel (openaiModel openaiWeakModel "medium");
          skills = [ ];
          mcps = [ ];
        };
        fixer = {
          model = fallbackModel strongModel (openaiModel openaiStrongModel "low");
          skills = [ ];
          mcps = [ ];
        };
      };
      neuralwatt = {
        orchestrator = {
          model = strongModel;
          skills = [ "*" ];
          mcps = [
            "*"
            "!context7"
          ];
        };
        oracle = {
          model = strongModel;
          skills = [ "simplify" ];
          mcps = [ ];
        };
        librarian = {
          model = midModel;
          skills = [ ];
          mcps = [
            "websearch"
            "context7"
            "gh_grep"
          ];
        };
        explorer = {
          model = weakModel;
          skills = [ ];
          mcps = [ ];
        };
        designer = {
          model = weakModel;
          skills = [ ];
          mcps = [ ];
        };
        fixer = {
          model = midModel;
          skills = [ ];
          mcps = [ ];
        };
      };
    };
    council = {
      default_preset = "cloudflare";
      councillor_execution_mode = "serial";
      presets.cloudflare = {
        architect.model = strongModel;
        implementer.model = midModel;
        skeptic.model = weakModel;
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
