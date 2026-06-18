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

  # Codex GPT-5.5 (smart tier) on the work machine via the built-in `openai`
  # provider, whose OAuth creds are mirrored from Codex CLI by maki-codex-sync
  # below;
  # Xiaomi MiMo Pro elsewhere. The full openai/gpt-5.* catalog (gpt-5.4 middle,
  # gpt-5.4-mini dumb) plus DeepSeek / CrofAI / gemma stay selectable via /model.
  defaultModel =
    if workModels then "openai/gpt-5.5" else "${aiXiaomi.providerId}/${aiXiaomi.models.mimoV25Pro.id}";

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
    require("start_worktree_session")
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
  mcpServers =
    cfg.mcpServers
    // lib.optionalAttrs cfg.byteroverMemory {
      byterover.command = [
        "brv"
        "mcp"
      ];
    };
  mcpToml = pkgs.writers.writeTOML "maki-mcp.toml" { mcp = mcpServers; };

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
  # maki's OpenAI login is device-code, blocked by the work ChatGPT workspace;
  # standard Codex browser login works. Mirror Codex's OAuth token into maki's
  # store on switch and on demand (`maki-codex-sync`). No-op when Codex has no
  # ChatGPT credential. Work Mac only.
  codexCredSync = pkgs.writeShellScriptBin "maki-codex-sync" ''
    exec ${pkgs.python3}/bin/python3 ${./codex-cred-sync.py}
  '';

in
{
  options.dotfiles.maki = {
    enable = lib.mkEnableOption "maki coding agent config" // {
      description = "Write ~/.config/maki config (init.lua, plugin.toml, custom Lua tools). The maki binary is installed manually.";
      default = true;
    };
    byteroverMemory = lib.mkEnableOption "byterover (brv) as maki's memory backend instead of the built-in memory tool";
    mcpServers = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
      default = { };
      description = ''
        MCP server definitions written to ~/.config/maki/mcp.toml. Maki uses
        TOML sections under [mcp.<name>]; stdio servers use command arrays.
      '';
    };
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
      ".config/maki/AGENTS.md" = {
        force = true;
        text = ''
           # Delegation
           - Decompose every non-trivial task into subtasks and delegate them. This is your default workflow.
           - Use `task(subagent_type="research")` for codebase exploration before making changes.
           - Use `task(subagent_type="general")` for implementation work: refactors, features, multi-file changes.
           - For complex work, decompose into subtasks, launch research subagents first, then implementation subagents — all in parallel using **batch**.
           - Use `task(model_tier="weak")` for cheap work: search, summarize, name things, simple edits.
           - Use `task(model_tier="medium")` for standard work: refactors, features, multi-file changes.
           - Use `task(model_tier="strong")` only for deep reasoning, complex architecture, subtle bugs, and the most critical sections.
           - Subagents are isolated — each gets a fresh context. Use this to avoid context bloat from unrelated work.
           - When you need the user to confirm before spawning, use `spawn_session` instead of `task`.
           - For long-running feature work that deserves its own worktree and Zellij tab, use `start_worktree_session`.
             First run `agent-branch-name --slug <slug> --task "<task>" --dry-run` to generate a branch name,
             prepare the session prompt, then call the tool with the branch and prompt.
           - Launch multiple tasks in a **batch** when you can. Parallel is the default, sequential is the exception.

          # Tool efficiency
          - Use **batch** for parallel tool calls (reads, greps, globs) within a single phase.
          - Use **code_execution** for chained/filtered tool calls (e.g. glob then filter, grep then read matches).
          - Use **task** for anything that can run independently. Combine with **batch** to parallelize research and implementation.

          # Workflow
          - Multi-step task → todo_write to plan → decompose → batch of task subagents → collect results → repeat.
          - Update todo_write after each step, not all at once.
          - Never commit or push unless asked.
          - Return concise summaries with `file_path:line_number` references. No code dumps.
        '';
      };

      ".config/maki/lua/spawn_session.lua" = {
        force = true;
        source = ./lua/spawn_session.lua;
      };
      ".config/maki/lua/start_worktree_session.lua" = {
        force = true;
        source = ./lua/start_worktree_session.lua;
      };
    }
    // lib.optionalAttrs (mcpServers != { }) {
      ".config/maki/mcp.toml" = {
        force = true;
        source = mcpToml;
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
    home.packages = lib.optional workModels codexCredSync;
    home.activation.makiCodexCreds = lib.mkIf workModels (
      lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        ${codexCredSync}/bin/maki-codex-sync || true
      ''
    );
  };
}
