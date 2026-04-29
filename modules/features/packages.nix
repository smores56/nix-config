{ pkgs, lib, ... }:
let
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
    - Always commit and push in a single call — never commit without immediately pushing
    - Local-only commits hide completed work

    # Communication
    - Be concise — no verbose explanations unless asked
    - Non-interactive CLI commands only (flags over interactive prompts)
  '';
in
{
  # Workaround: Stylix's opencode module references programs.opencode.tui
  # which doesn't exist in the current home-manager version
  options.programs.opencode.tui = lib.mkOption {
    type = lib.types.anything;
    default = { };
  };

  config.programs.bat.enable = true;
  config.programs.fzf.enable = true;
  config.programs.k9s.enable = true;

  config.home.sessionVariables = {
    DISABLE_NIX_SHELL_WELCOME = 1;
    OLLAMA_HOST = "http://smortress:11434";
    OLLAMA_CONTEXT_LENGTH = "32768";
    OPENAI_MODEL = "gemma4:26b-a4b-it-q4_K_M";
    GOOSE_DISABLE_KEYRING = "true";
  };

  config.xdg.configFile."goose/config.yaml".text = ''
    # Managed by nix — edit modules/features/packages.nix instead
    GOOSE_PROVIDER: "ollama"
    GOOSE_MODEL: "gemma4:26b-a4b-it-q4_K_M"
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
      fetch:
        enabled: true
        type: builtin
        name: fetch
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

  config.home.file.".goosehints".text = aiHints;
  config.home.file.".claude/CLAUDE.md".text = aiHints;

  config.home.packages = with pkgs; [
    # exploration
    eza
    fd
    ripgrep
    glow
    television
    openssh

    # data interaction
    jq
    eva
    curl
    sd
    ouch
    zip
    unzip
    lazysql

    # environment management
    awscli2
    aws-sso-cli
    _1password-cli

    # monitoring
    dua
    tokei
    bottom
    watchexec

    # languages
    go
    uv
    python3
    deno
    typst
    cargo

    # compilation
    gcc
    pkg-config
    openssl.dev

    # fun stuff
    cbonsai
    musikcube
    clock-rs
    ttyper

    # TUI utilities
    gum
    goose-cli

    # container tools
    lazydocker
    docker-compose
    kubernetes-helm
    kubectl
    kubectx
  ];
}
