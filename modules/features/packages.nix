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
  };

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

    # container tools
    lazydocker
    docker-compose
    kubernetes-helm
    kubectl
    kubectx
  ];
}
