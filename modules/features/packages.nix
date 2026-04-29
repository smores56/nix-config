{ pkgs, lib, ... }:
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
    OPENAI_MODEL = "qwen3.6:27b";
    GOOSE_DISABLE_KEYRING = "true";
  };

  config.xdg.configFile."goose/config.yaml".text = ''
    GOOSE_PROVIDER: "ollama"
    GOOSE_MODEL: "qwen3.6:27b"
    GOOSE_MODE: "auto"
    GOOSE_TELEMETRY_ENABLED: false
    GOOSE_CLI_THEME: "dark"
    GOOSE_AUTO_COMPACT_THRESHOLD: 0.8

    extensions:
      developer:
        enabled: true
        type: builtin
        name: developer
        timeout: 300
  '';

  config.home.file.".goosehints".text = ''
    Prefer functional programming patterns.
    Write clean code without unnecessary comments.
    Use Nix, home-manager, and flake-parts conventions when editing .nix files.
    This user edits code in Helix and runs AI tools in a separate Zellij tab.
  '';

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
