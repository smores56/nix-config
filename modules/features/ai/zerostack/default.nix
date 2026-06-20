{
  config,
  lib,
  pkgs,
  aiDeepseek,
  aiNeuralwatt,
  aiXiaomi,
  ...
}:
let
  cfg = config.dotfiles.zerostack;
  workModels = config.dotfiles.workModels;

  # zerostack has no built-in `openai-codex` provider name (its built-ins are
  # openrouter/openai/anthropic/gemini/ollama), and Codex OAuth tokens rotate,
  # so on the work machine we don't try to wire Codex tiers the way pi/omp do.
  # Work host falls back to anthropic (Claude OAuth via api_keys), model picked
  # at /model time. Personal hosts get the full Neuralwatt/Deepseek/Xiaomi set
  # as OpenAI-compatible `custom_providers`.
  enabledProviders = lib.optionalAttrs (!workModels) {
    ${aiNeuralwatt.providerId} = {
      provider_type = "openai";
      base_url = aiNeuralwatt.baseUrl;
      api_key_env = "NEURALWATT_API_KEY";
      api_style = "completions";
    };
    ${aiDeepseek.providerId} = {
      provider_type = "openai";
      base_url = aiDeepseek.baseUrl;
      api_key_env = "DEEPSEEK_API_KEY";
      api_style = "completions";
    };
    ${aiXiaomi.providerId} = {
      provider_type = "openai";
      base_url = aiXiaomi.baseUrl;
      api_key_env = "XIAOMI_MIMO_API_KEY";
      api_style = "completions";
    };
  };

  # Model refs in zerostack's `<provider>/<model>` form.
  nwStrong = "${aiNeuralwatt.providerId}/${aiNeuralwatt.models.glm52.id}";
  nwMid = "${aiNeuralwatt.providerId}/${aiNeuralwatt.models.qwen35.id}";
  nwWeak = "${aiNeuralwatt.providerId}/${aiNeuralwatt.models.qwen36.id}";
  dsStrong = "${aiDeepseek.providerId}/${aiDeepseek.models.v4Pro.id}";
  dsMid = "${aiDeepseek.providerId}/${aiDeepseek.models.v4Flash.id}";
  xmWeak = "${aiXiaomi.providerId}/${aiXiaomi.models.mimoV25.id}";
  xmStrong = "${aiXiaomi.providerId}/${aiXiaomi.models.mimoV25Pro.id}";

  # Three-tier quick_models (switchable via `/models <name>` or `--quick-model`).
  # Tiers map to the same provider/model split the other agents use:
  #   strong = Neuralwatt GLM-5.2 (1M ctx, reasoning) — main session + planning
  #   medium = Deepseek V4 Pro   — general implementation, fallback for strong
  #   weak   = Xiaomi MiMo V2.5  — scouts, naming, summaries, side questions
  # Each tier is also switchable standalone with `/models strong|medium|weak`.
  quickModels = lib.optionalAttrs (!workModels) {
    strong = {
      provider = aiNeuralwatt.providerId;
      model = aiNeuralwatt.models.glm52.id;
      reserve_tokens = 8192;
    };
    medium = {
      provider = aiDeepseek.providerId;
      model = aiDeepseek.models.v4Pro.id;
      reserve_tokens = 8192;
    };
    weak = {
      provider = aiXiaomi.providerId;
      model = aiXiaomi.models.mimoV25.id;
      reserve_tokens = 4096;
    };
    # `fast` alias mirrors zerostack's default quick-model name so `/models fast`
    # keeps working as a cheap-tier escape hatch even after this config loads.
    fast = {
      provider = aiXiaomi.providerId;
      model = aiXiaomi.models.mimoV25.id;
      reserve_tokens = 4096;
    };
  };

  # zerostack's subagent (`task` tool) uses a SINGLE model+provider for all
  # read-only child investigations — there is no per-tier override like pi's
  # scout/worker/planner split. Pin the cheap tier so codebase exploration stays
  # cheap; the main agent stays on `strong` for the real work. Override at runtime
  # with `/subagent-model`/`/subagent-provider` if a heavyweight investigation is
  # needed. (See https://github.com/gi-dellav/zerostack/blob/main/docs/SUBAGENTS.md)
  subagentModel = lib.optionalAttrs (!workModels) {
    subagent_model = aiXiaomi.models.mimoV25.id;
    subagent_provider = aiXiaomi.providerId;
    task_max_turns = 15;
    task_enabled = true;
  };

  # Advisor = escalation path from the running (strong/medium) model to a
  # stronger reviewer for strategic calls. Emulates the "strong tier for
  # critical sections" slot pi/omp fill with the planner/reviewer/oracle roles.
  # Disabled on work (no Codex tier to escalate to via zerostack).
  advisor = lib.optionalAttrs (!workModels) {
    enabled = true;
    model = aiNeuralwatt.models.glm52.id;
    provider = aiNeuralwatt.providerId;
    max_uses = 3;
    human_handoff = false;
    advisor_kilobytes_limit = 256;
  };

  # Permission rules: yolo by default within CWD (matches maki's always_yolo),
  # deny rm -rf and friends, allow read-only tools. zerostack's `standard` mode
  # already auto-allows safe bash; we layer a couple of explicit denies on top.
  permission = {
    "*" = "ask";
    read = "allow";
    grep = "allow";
    find_files = "allow";
    list_dir = "allow";
    write."**" = "allow";
    edit."**" = "allow";
    bash = {
      "rm -rf **" = "deny";
      "rm -fr **" = "deny";
      "sudo **" = "deny";
      "git push --force**" = "deny";
    };
    doom_loop = "ask";
    external_directory = {
      "/tmp/**" = "allow";
      "/**" = "ask";
    };
  };

  # Sessions/sessions dir + compaction. zerostack auto-detects context_window
  # from the model catalog; only set reserve + keep_recent so MiMo's 1M ctx
  # doesn't hold 200k of stale tool output.
  compaction = {
    compact_enabled = true;
    mid_turn_compact_threshold = 0.80;
    keep_recent_tokens = 10000;
  };

  # The stdio MCP server that lets a running zerostack hand off to a sibling
  # zerostack session in a fresh Zellij tab on a new worktree. See
  # ./mcp/zellij_session_server.py. Registered under `zerostack_session` so the
  # tool name is `mcp_tool:zerostack_session:start_zerostack_session`.
  mcpServerScript = pkgs.writeText "zellij_session_server.py" (
    builtins.readFile ./mcp/zellij_session_server.py
  );
  # Small wrapper so zerostack spawns python3 on the store-pinned script (the
  # raw config `command` is just the binary name; args is the script path).
  # `python3` is expected on PATH (it is, via the nono profile + system).
  zellijSessionMcpServer = {
    command = "python3";
    args = [ "${mcpServerScript}" ];
  };

  zerostackConfig =
    {
      max_tokens = 16384;
      default_prompt = "code";
      default_permission_mode = "yolo";
      show_tool_details = 3;
      edit_system = "similarity";
      deny_repeated_reads = false;
      enable-exa-mcp = false; # Exa needs EXA_API_KEY; disable to silence probe noise
      # yolo mode auto-allows non-destructive ops; the session-spawn MCP tool is
      # not destructive (it opens a tab), so it goes through without a prompt —
      # matches maki's always_yolo + start_worktree_session (no confirm gate).
      custom_providers = enabledProviders;
      inherit quickModels;
      permission = permission;
      inherit compaction;
      mcp_servers.zerostack_session = zellijSessionMcpServer;
    }
    // (lib.optionalAttrs (!workModels) {
      # Personal hosts: default to Neuralwatt GLM-5.2 (strong tier).
      # Work host: provider/model left unset — zerostack falls back to its
      # built-in default and the user picks via `/model` (Codex/Anthropic OAuth
      # isn't wired here the way pi/omp do; see README follow-up note).
      provider = aiNeuralwatt.providerId;
      model = aiNeuralwatt.models.glm52.id;
    })
    // (lib.optionalAttrs (!workModels) subagentModel)
    // (lib.optionalAttrs (!workModels) { inherit advisor; });

  configToml = pkgs.writers.writeTOML "zerostack-config" zerostackConfig;

  # Per-project AGENTS.md + global rules zerostack auto-loads from cwd/ancestor
  # dirs. Keep these in the nix-managed config dir so a fresh checkout still has
  # them; zerostack also reads cwd/AGENTS.md if present (project-local overrides).
  agentsMd = ''
    # zerostack

    Coding agent config managed by home-manager
    (`modules/features/ai/zerostack`). Binary installed manually and on $PATH.

    # Delegation
    - Use the `task` tool (read-only subagent) for MULTI-FILE investigations
      (3+ files to cross-reference). Do NOT use it for single grep/read/list_dir.
    - Multiple `task` prompts run in parallel — batch independent investigations.
    - The subagent runs on the cheap tier (Xiaomi MiMo). Escalate to the strong
      tier (Neuralwatt GLM-5.2) yourself for the actual edits.

    # Tiers
    - Main session: `strong` quick-model (Neuralwatt GLM-5.2).
    - Switch at runtime: `/models strong` / `/models medium` / `/models weak`.
    - Advisor (escalation): enabled, routes to GLM-5.2 with a 3-call budget.

    # Worktree handoff
    - For long-horizon subtasks that deserve isolation, call the
      `zerostack_session.start_zerostack_session` MCP tool. It creates a git
      worktree (via worktrunk `wt`) and opens a NEW zerostack TUI in a fresh
      Zellij tab on that worktree, with the prompt you pass as its first message.
    - Resolve a branch name FIRST: `agent-branch-name --slug <slug> --task "<task>" --dry-run`.
    - The new tab runs interactively; switch to it to steer the sibling session.

    # Commits
    - Conventional Commits (`feat`, `fix`, `refactor`, ...). No AI attribution.
    - Push immediately after committing.

    # Retry discipline
    If a command returns unexpected output more than twice, stop and investigate.
  '';
in
{
  options.dotfiles.zerostack = {
    enable = lib.mkEnableOption "zerostack coding agent config" // {
      description = ''
        Write ~/.config/zerostack/config.toml (providers, quick_models, subagent
        + advisor tiers, permission rules, compaction) plus the stdio MCP server
        that lets a running zerostack spawn an isolated sibling zerostack in a
        new Zellij tab. The zerostack binary itself is installed manually and
        must already be on $PATH.
      '';
      default = true;
    };
  };

  config = lib.mkIf cfg.enable {
    home.file = {
      ".config/zerostack/config.toml" = {
        force = true;
        source = configToml;
      };
      ".config/zerostack/AGENTS.md" = {
        force = true;
        text = agentsMd;
      };
    };

    # `z` launches zerostack under the nono sandbox, mirroring the `m`/`o`/`pi`
    # abbreviations. The agent profile (modules/features/ai/nono.nix) is updated
    # to allowlist ~/.config/zerostack + ~/.local/share/zerostack so zerostack
    # can read its config and write sessions without EACCES.
    programs.fish.shellAbbrs.z = "nono run -s -- zerostack";
  };
}
