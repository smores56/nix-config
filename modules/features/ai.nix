{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles;
  inherit (cfg) branchPrefix;

  piNpm = pkgs.writeShellScriptBin "pi-npm" ''
    export PATH="${pkgs.nodejs}/bin:$PATH"
    export NPM_CONFIG_PREFIX="$HOME/.pi/agent/npm-global"
    mkdir -p "$NPM_CONFIG_PREFIX"
    exec ${pkgs.nodejs}/bin/npm "$@"
  '';
  piNpx = pkgs.writeShellScriptBin "npx" ''
    export PATH="${pkgs.nodejs}/bin:$PATH"
    export NPM_CONFIG_PREFIX="$HOME/.pi/agent/npm-global"
    mkdir -p "$NPM_CONFIG_PREFIX"
    exec ${pkgs.nodejs}/bin/npx "$@"
  '';

  workBranchWorkflow = ''
    - Branch format: `${branchPrefix}/${cfg.ticketPrefix}-<ticket-number>-<kebab-slug>`
    - Example: `${branchPrefix}/${cfg.ticketPrefix}-12345-fix-auth-flow`
    - Every change must reference a ${cfg.ticketPrefix} Linear ticket
    - To create a ticket: `linear issue create -t "Title" --team ${cfg.ticketPrefix} --assignee self --start`
    - To list your tickets: `linear issue mine`
    - To view a ticket: `linear issue view ${cfg.ticketPrefix}-<number>`
    - Create worktrees with gwq: `gwq add -b ${branchPrefix}/${cfg.ticketPrefix}-<ticket-number>-<kebab-slug>`
    - Do NOT use `git worktree add` or Claude's built-in EnterWorktree — always use `gwq add -b`
    - Worktrees are stored in ~/dev/worktrees/, organized by repo URL path
    - List worktrees for current repo: `gwq list`
    - List all worktrees: `gwq list -g`
    - Remove a worktree: `gwq remove <path>`
  '';

  personalBranchWorkflow = ''
    - Branch format: `${branchPrefix}/<kebab-slug>`
    - Example: `${branchPrefix}/fix-auth-flow`
    - Create worktrees with gwq: `gwq add -b ${branchPrefix}/<kebab-slug>`
    - Do NOT use `git worktree add` or Claude's built-in EnterWorktree — always use `gwq add -b`
    - Worktrees are stored in ~/dev/worktrees/, organized by repo URL path
    - List worktrees for current repo: `gwq list`
    - List all worktrees: `gwq list -g`
    - Remove a worktree: `gwq remove <path>`
  '';

  branchWorkflow = if cfg.ticketPrefix != null then workBranchWorkflow else personalBranchWorkflow;

  aiHints = ''
    # Code Style
    - Strongly prefer functional programming: pure functions, immutability, composition over inheritance
    - Single-purpose functions — no flag parameters, no multi-mode behavior
    - Prefer pattern matching and algebraic data types where available
    - Prefer early returns and guard clauses over nested conditionals
    - Prefer structured types over untyped dictionaries/maps/objects

    # Comments
    - No comments on self-explanatory code
    - Comments explain WHY, never WHAT
    - No multi-line comment blocks or verbose docstrings

    # Data
    - Transform data at point of use — keep it in its richest form until the consumer needs a different shape
    - Avoid eager conversion (loses information prematurely) and lazy conversion (adds redundant intermediates)

    # Error Handling
    - Errors must be explicit — never silently swallow or fall back
    - Prefer Result/Option/Either types and typed error variants over exceptions or string messages
    - Error messages must include enough context to debug without a stack trace

    # Design Process
    - IMPORTANT: Ask design questions before implementing — clarify ambiguity rather than guessing
    - When the approach is unclear, propose 2-3 options with tradeoffs
    - Scope changes narrowly — no broad refactors unless explicitly requested

    # Testing
    - Add tests when the change warrants it
    - Prefer real dependencies over mocks
    - Match test scope to the change being made

    # Git Workflow
    - ALL repos should be cloned to ~/dev/repos/ (managed by ghq, organized as ~/dev/repos/github.com/org/repo/)
    - ALL worktrees should be created in ~/dev/worktrees/ (managed by gwq, organized by repo URL path)
    - Always commit and push in a single call — never commit without immediately pushing
    - Local-only commits hide completed work
    ${branchWorkflow}
    # Communication
    - Be concise — no verbose explanations unless asked
    - Non-interactive CLI commands only (flags over interactive prompts)
  '';

  ticketLikeTerms = [
    "ticket"
    "tickets"
    "issue"
    "issues"
    "linear"
    "jira"
    "work item"
    "work items"
  ];
  containsTicketLikeTerm =
    text: builtins.any (term: lib.hasInfix term (lib.toLower text)) ticketLikeTerms;

  smortressBaseUrl = "http://smortress:8080";
  smortressCompat = {
    supportsStore = false;
    supportsDeveloperRole = false;
    supportsReasoningEffort = false;
    supportsUsageInStreaming = true;
    maxTokensField = "max_tokens";
  };
  smortressModels = [
    {
      id = "qwen3.6-27b";
      name = "Qwen 3.6 27B";
      reasoning = false;
      input = [ "text" ];
      contextWindow = 131072;
      maxTokens = 8192;
      cost = {
        input = 0;
        output = 0;
        cacheRead = 0;
        cacheWrite = 0;
      };
    }
  ];

  piSettingsJson = builtins.toJSON {
    defaultProvider = "smortress";
    inherit (cfg) defaultModel;
    npmCommand = [ "${piNpm}/bin/pi-npm" ];
    packages = [
      "npm:pi-subagents@0.24.2"
      "npm:pi-intercom@0.6.0"
      "npm:pi-interactive-shell@0.13.0"
      {
        source = "npm:pi-messenger-swarm@0.25.4";
        extensions = [ ];
        skills = [ "./skills" ];
      }
      "npm:@earendil-works/pi-agent-core@0.74.0"
      "npm:@earendil-works/pi-ai@0.74.0"
      "npm:@earendil-works/pi-coding-agent@0.74.0"
      "npm:@earendil-works/pi-tui@0.74.0"
      "npm:@mariozechner/pi-tui@0.73.1"
      "npm:tsx@4.21.0"
    ];
    compaction = {
      enabled = true;
    };
  };

  piModelsJson = builtins.toJSON {
    providers = {
      smortress = {
        baseUrl = "${smortressBaseUrl}/v1";
        apiKey = "PI_SMORTRESS_API_KEY";
        api = "openai-completions";
        compat = smortressCompat;
        models = smortressModels;
      };
    };
  };
in
{
  assertions = [
    {
      assertion = cfg.ticketPrefix != null || !containsTicketLikeTerm aiHints;
      message = "Non-work CLAUDE.md must not mention tickets, issues, Linear, Jira, or work items.";
    }
  ];

  home = {
    packages = [
      pkgs.goose-cli
      pkgs.pi-coding-agent
      piNpm
      piNpx
    ];

    sessionVariables = {
      OPENAI_HOST = smortressBaseUrl;
      GOOSE_CONTEXT_LIMIT = "131072";
      OPENAI_MODEL = cfg.defaultModel;
      PI_SMORTRESS_API_KEY = "not-needed";
      GOOSE_DISABLE_KEYRING = "true";
    };

    file = {
      ".goosehints".text = aiHints;
      ".claude/CLAUDE.md".text = aiHints;
      "AGENTS.md".text = aiHints;
      ".pi/agent/extensions/pi-supervisor.ts".source = ./ai/pi-supervisor.ts;
      ".pi/agent/extensions/pi-messenger-swarm.js".text = ''
        export { default } from "${config.home.homeDirectory}/.pi/agent/npm-global/lib/node_modules/pi-messenger-swarm/dist/index.js";
      '';
      ".pi/agent/settings.json" = {
        text = piSettingsJson;
        force = true;
      };
      ".pi/agent/models.json" = {
        text = piModelsJson;
        force = true;
      };
    };
  };

  xdg.configFile."goose/config.yaml" = {
    force = true;
    text = ''
      # Managed by nix — edit modules/features/ai.nix instead
      GOOSE_PROVIDER: "openai"
      GOOSE_MODEL: "${cfg.defaultModel}"
      GOOSE_MODE: "auto"
      GOOSE_TELEMETRY_ENABLED: false
      GOOSE_CLI_THEME: "dark"
      GOOSE_AUTO_COMPACT_THRESHOLD: 0.8
      GOOSE_TOOLSHIM: true

      extensions:
        developer:
          enabled: true
          type: builtin
          name: developer
          timeout: 300
        memory:
          enabled: true
          type: builtin
          name: memory
          timeout: 300
        code_execution:
          enabled: true
          type: platform
          name: code_execution
        skills:
          enabled: true
          type: platform
          name: skills
        todo:
          enabled: true
          type: platform
          name: todo
        extensionmanager:
          enabled: true
          type: platform
          name: Extension Manager
    '';
  };
}
