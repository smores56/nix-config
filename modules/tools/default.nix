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

    # container tools
    k9s
    lazydocker
    docker-compose
    kubernetes-helm
    kubectl
    kubectx
  ];
}
