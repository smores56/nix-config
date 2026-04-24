{ pkgs, ... }:
{
  imports = [
    ./fish
    ./git.nix
    ./helix.nix
    ./theme.nix
    ./yazi.nix
    ./zellij.nix
  ];

  home.sessionVariables = {
    DISABLE_NIX_SHELL_WELCOME = 1;
  };

  home.packages = with pkgs; [
    # exploration
    zoxide
    eza
    fd
    bat
    ripgrep
    glow
    fzf
    delta
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
    zellij
    direnv
    awscli2
    aws-sso-cli
    _1password-cli

    # AI tools
    # claude-code
    gemini-cli

    # monitoring
    dua
    bottom
    tokei
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

    # container tools
    k9s
    # oxker
    docker-compose
    kubernetes-helm
    kubectl
    kubectx

    # other packages
    xsel
    python313Packages.dvc
    python313Packages.playwright
    websocat
    argocd
  ];
}
