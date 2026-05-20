{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles;
  inherit (cfg) branchPrefix;

  revdiff-src = pkgs.fetchFromGitHub {
    owner = "umputun";
    repo = "revdiff";
    tag = "v1.3.0";
    hash = "sha256-lcqkvQ5jLP3sA9WeFcp1PRPIvtq7vWjl7M+9juBYXL0=";
  };

  revdiff = pkgs.buildGoModule rec {
    pname = "revdiff";
    version = "1.3.0";
    src = revdiff-src;
    vendorHash = null;
    ldflags = [
      "-s"
      "-w"
      "-X main.version=v${version}"
    ];
    doCheck = false;
    postInstall = ''
      mv $out/bin/app $out/bin/revdiff
    '';
  };

  piNpm = pkgs.writeShellScriptBin "pi-npm" ''
    export PATH="${pkgs.nodejs}/bin:$PATH"
    export NPM_CONFIG_PREFIX="$HOME/.pi/agent/npm-global"
    mkdir -p "$NPM_CONFIG_PREFIX"
    exec ${pkgs.nodejs}/bin/npm "$@"
  '';

  hasTicket = cfg.ticketPrefix != null;
  branchSlug =
    if hasTicket then "${cfg.ticketPrefix}-<ticket-number>-<kebab-slug>" else "<kebab-slug>";
  exampleSlug = if hasTicket then "${cfg.ticketPrefix}-12345-fix-auth-flow" else "fix-auth-flow";
  waArg = if hasTicket then "<ticket-number>-<kebab-slug>" else "<kebab-slug>";

  branchWorkflowLines = [
    "- Branch format: `${branchPrefix}/${branchSlug}`"
    "- Example: `${branchPrefix}/${exampleSlug}`"
  ]
  ++ lib.optionals hasTicket [
    "- Every change must reference a ${cfg.ticketPrefix} Linear ticket"
    "- To create a ticket: `linear issue create -t \"Title\" --team ${cfg.ticketPrefix} --assignee self --start`"
    "- To list your tickets: `linear issue mine`"
    "- To view a ticket: `linear issue view ${cfg.ticketPrefix}-<number>`"
  ]
  ++ [
    "- Create worktrees with `wa ${waArg}` (expands to `wt switch --create ${branchPrefix}/${branchSlug}`)"
    "- Or directly: `wt switch --create ${branchPrefix}/${branchSlug}` (or `wc` abbrev)"
    "- Worktree directories are siblings of the repo: `<repo>.${branchSlug}` (worktrunk strips the `${branchPrefix}/` prefix)"
    "- Switch between worktrees: `w` (fuzzy picker via tv; interactive) or `wt switch <branch>` to jump directly"
    "- To return to the canonical (non-worktree) checkout: `cd ${cfg.codeRoot}/github.com/<owner>/<repo>`"
    "- Do NOT use `git clone`, `git worktree add`, `git checkout -b`, or Claude's built-in EnterWorktree"
    "- List worktrees: `wt list` (or `wl` abbrev)"
    "- Remove a worktree: `wt remove` (or `wx` abbrev) — from inside it, or with explicit `<branch>`"
  ];

  branchWorkflow = lib.concatStringsSep "\n" branchWorkflowLines;

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

    # Testing
    - Add tests when the change warrants it
    - Prefer real dependencies over mocks
    - Match test scope to the change being made

    # Git Workflow
    - ALL repos live under `${cfg.codeRoot}/` and are managed by `ghq` (layout: `${cfg.codeRoot}/<host>/<owner>/<repo>`)
    - Clone repos: `ghq get <owner/repo-or-url>`. Never `git clone` directly
    - Find repos: `ghq list -p | grep <name>` (the `r` fish function is interactive-only)
    - ALL worktrees follow the siblings pattern via `worktrunk` (`wt`)
    - Worktree of branch `${branchPrefix}/X` lives at `<repo>.X` (sibling of the main checkout; the `${branchPrefix}/` prefix is stripped from the directory name)
    - Use `lazygit` from any worktree; it reads `git worktree list` natively
    - Always push immediately after committing — never leave local-only commits
    - Do not add `Co-Authored-By` trailers to commit messages (no AI attribution)
    ${branchWorkflow}

    # Commits and PRs
    - Follow Conventional Commits: <https://www.conventionalcommits.org/en/v1.0.0/>
    - Types: feat, fix, refactor, chore, docs, test, perf, ci
    ${
      if hasTicket then
        "- Scope is the Linear ticket: `type(${cfg.ticketPrefix}-<number>): description` (e.g. `fix(${cfg.ticketPrefix}-123): resolve token refresh`)"
      else
        "- Scope is the affected module or area: `type(scope): description`"
    }
    - Applies to both commit messages and PR titles

    # Communication
    - Be concise — no verbose explanations unless asked
    - Non-interactive CLI commands only (flags over interactive prompts)
  '';

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
  config = {
    home = {
      packages = [
        pkgs.goose-cli
        pkgs.pi-coding-agent
        piNpm
        revdiff
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
        ".pi/agent/extensions/pi-supervisor.ts".source = ./pi-supervisor.ts;
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

    dotfiles.aiHints = aiHints;

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
            enabled = true;
            type: platform
            name: Extension Manager
      '';
    };
  };
}
