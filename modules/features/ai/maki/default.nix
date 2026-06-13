{
  config,
  lib,
  aiDeepseek,
  ...
}:
let
  cfg = config.dotfiles.maki;
  workModels = config.dotfiles.workModels;

  # Mirror pi/oh-my-pi: Anthropic Opus drives the work machine, the DeepSeek
  # tier (a provider maki supports natively, key already in api-keys.fish)
  # everywhere else. claude-fable-5 stays selectable from maki's built-in
  # anthropic strong-tier catalog (/model or --model anthropic/claude-fable-5).
  defaultModel =
    if workModels then
      "anthropic/claude-opus-4-8"
    else
      "${aiDeepseek.providerId}/${aiDeepseek.models.v4Pro.id}";

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
    };
  };
}
