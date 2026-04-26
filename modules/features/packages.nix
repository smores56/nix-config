{ pkgs, ... }:
{
  home.sessionVariables = {
    DISABLE_NIX_SHELL_WELCOME = 1;
  };

  home.packages = with pkgs; [
    # exploration
    eza
    fd
    bat
    ripgrep
    glow
    fzf
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
    k9s
    lazydocker
    docker-compose
    kubernetes-helm
    kubectl
    kubectx
  ];
}
