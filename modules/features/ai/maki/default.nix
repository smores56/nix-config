{
  config,
  lib,
  pkgs,
  aiXiaomi,
  aiCrofai,
  ...
}:
let
  cfg = config.dotfiles.maki;
  workModels = config.dotfiles.workModels;

  # Mirror pi/oh-my-pi's personal default: Anthropic Opus on the work machine,
  # Xiaomi MiMo Pro (registered via the custom provider below) elsewhere. The
  # DeepSeek / CrofAI / gemma tiers stay selectable as backups via /model, never
  # the default. claude-fable-5 stays in maki's built-in anthropic strong catalog.
  defaultModel =
    if workModels then
      "anthropic/claude-opus-4-8"
    else
      "${aiXiaomi.providerId}/${aiXiaomi.models.mimoV25Pro.id}";

  # byterover (brv) replaces the built-in memory tool when enabled.
  makiTools = [
    "bash = { enabled = true }"
  ]
  ++ lib.optional cfg.byteroverMemory "memory = { enabled = false }";
  toolsBlock = lib.concatMapStrings (t: "\n        " + t + ",") makiTools;

  # init.lua is a Lua script that calls maki.setup() once, then loads custom
  # tools. always_yolo skips permission prompts (deny rules still apply);
  # always_thinking turns on adaptive extended thinking. bash is off by default
  # in maki, so enable it to match pi/oh-my-pi's coding-agent toolset.
  initLua = ''
    -- Managed by home-manager (modules/features/ai/maki). Manual edits are clobbered.
    maki.setup({
      always_yolo = true,
      always_thinking = true,
      provider = {
        default_model = "${defaultModel}",
      },
      tools = {${toolsBlock}
      },
    })

    require("spawn_session")
  '';

  # Grants this config's Lua plugins process-spawn (`run`) and env access,
  # needed by spawn_session's `paseo run`. With no manifest maki denies every
  # plugin capability, so the file must exist even for a single tool.
  pluginToml = ''
    [permissions]
    run = true
    env = true
  '';

  # brv's MCP server (`brv mcp`) supplies memory tools (byterover__curate /
  # byterover__query / ...) in place of the disabled built-in memory. brv must
  # be on maki's PATH; tools are namespaced `byterover__*`.
  mcpToml = ''
    # Managed by home-manager (modules/features/ai/maki). Manual edits are clobbered.
    [mcp.byterover]
    command = ["brv", "mcp"]
  '';

  # mimo / crofai / gemma are OpenAI-compatible endpoints maki ships no built-in
  # for. maki discovers custom providers as executable scripts in
  # ~/.config/maki/providers/<slug> answering info/models/resolve. base
  # "llama-cpp" selects the plain OpenAI /v1 chat-completions dialect (no
  # Responses API / developer role) that all three speak; resolve injects the
  # bearer token and info's has_auth reflects whether the key env var is set, so
  # a provider only lights up when its creds are available. Personal hosts only —
  # work hosts drive anthropic/openai-codex.
  makiProviders = {
    ${aiXiaomi.providerId} = {
      displayName = "Xiaomi MiMo";
      baseUrl = aiXiaomi.baseUrl;
      keyEnv = "XIAOMI_MIMO_API_KEY";
      models = [
        {
          id = aiXiaomi.models.mimoV25Pro.id;
          tier = "strong";
          context_window = aiXiaomi.models.mimoV25Pro.context;
          max_output_tokens = aiXiaomi.models.mimoV25Pro.output;
        }
        {
          id = aiXiaomi.models.mimoV25.id;
          tier = "weak";
          context_window = aiXiaomi.models.mimoV25.context;
          max_output_tokens = aiXiaomi.models.mimoV25.output;
        }
      ];
    };
    ${aiCrofai.providerId} = {
      displayName = "CrofAI";
      baseUrl = aiCrofai.baseUrl;
      keyEnv = "CROFAI_API_KEY";
      models = [
        {
          id = aiCrofai.models.kimiK27Code.id;
          tier = "strong";
          context_window = aiCrofai.models.kimiK27Code.context;
          max_output_tokens = aiCrofai.models.kimiK27Code.output;
        }
      ];
    };
    smortress = {
      displayName = "Gemma (smortress)";
      baseUrl = "http://smortress:8081/v1";
      keyEnv = null;
      models = [
        {
          id = "gemma-4-31b";
          tier = "medium";
          context_window = 102400;
          max_output_tokens = 102400;
        }
      ];
    };
  };

  mkProviderScript =
    p:
    let
      hasKey = p.keyEnv != null;
      infoCmd =
        if hasKey then
          ''
            if [ -n "''${${p.keyEnv}:-}" ]; then ha=true; else ha=false; fi
            printf '{"display_name":%s,"base":"llama-cpp","has_auth":%s}\n' ${lib.escapeShellArg (builtins.toJSON p.displayName)} "$ha"''
        else
          ''printf '%s\n' ${
            lib.escapeShellArg (
              builtins.toJSON {
                display_name = p.displayName;
                base = "llama-cpp";
                has_auth = true;
              }
            )
          }'';
      resolveCmd =
        if hasKey then
          ''printf '{"base_url":%s,"headers":{"Authorization":"Bearer %s"}}\n' ${lib.escapeShellArg (builtins.toJSON p.baseUrl)} "''${${p.keyEnv}:-}"''
        else
          ''printf '%s\n' ${
            lib.escapeShellArg (
              builtins.toJSON {
                base_url = p.baseUrl;
                headers = { };
              }
            )
          }'';
    in
    ''
      #!${pkgs.bash}/bin/bash
      # Managed by home-manager (modules/features/ai/maki). Manual edits are clobbered.
      set -euo pipefail
      case "''${1:-}" in
        info)
          ${infoCmd}
          ;;
        models)
          printf '%s\n' ${lib.escapeShellArg (builtins.toJSON p.models)}
          ;;
        resolve)
          ${resolveCmd}
          ;;
      esac
    '';
in
{
  options.dotfiles.maki = {
    enable = lib.mkEnableOption "maki coding agent config" // {
      description = "Write ~/.config/maki config (init.lua, plugin.toml, custom Lua tools). The maki binary is installed manually.";
      default = true;
    };
    byteroverMemory = lib.mkEnableOption "byterover (brv) as maki's memory backend instead of the built-in memory tool";
  };

  config = lib.mkIf cfg.enable {
    home.file = {
      ".config/maki/init.lua" = {
        force = true;
        text = initLua;
      };
      ".config/maki/plugin.toml" = {
        force = true;
        text = pluginToml;
      };
      ".config/maki/lua/spawn_session.lua" = {
        force = true;
        source = ./lua/spawn_session.lua;
      };
    }
    // lib.optionalAttrs cfg.byteroverMemory {
      ".config/maki/mcp.toml" = {
        force = true;
        text = mcpToml;
      };
    }
    // lib.optionalAttrs (!workModels) (
      lib.mapAttrs' (
        slug: p:
        lib.nameValuePair ".config/maki/providers/${slug}" {
          force = true;
          executable = true;
          text = mkProviderScript p;
        }
      ) makiProviders
    );
  };
}
