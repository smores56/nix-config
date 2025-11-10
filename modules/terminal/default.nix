{ pkgs, ... }:
{
  imports = [
    ./shell
    ./editor
    ./emulator
    ./git.nix
    ./file-manager
    ./multiplexer
  ];

  home.sessionVariables = {
    GUM_CHOOSE_CURSOR_FOREGROUND = 3;
    DISABLE_NIX_SHELL_WELCOME = 1;
  };

  home.packages = with pkgs; [
    # exploration
    zoxide
    eza
    fd
    ripgrep
    glow
    fzf
    jq
    jaq
    jqp
    delta
    television
    lazysql

    # AI tools
    claude-code
    ollama
    smartcat
    opencode
    aichat
    gemini-cli
    gpt-cli

    # editing
    sd
    ouch
    zip
    unzip

    # monitoring
    dua
    bottom
    tokei
    bandwhich

    # security
    yara
    yara-x

    # languages
    go
    uv
    python3
    deno
    yarn
    nodePackages.pnpm
    erg
    typst
    idris2
    fnm
    zig
    buf
    terraform

    # rust
    rustup

    # compilation
    gcc
    pkg-config
    openssl.dev

    # fun stuff
    gum
    cbonsai
    musikcube
    clock-rs
    ttyper

    # container tools
    k9s
    docker-compose
    # oxker
    kubernetes-helm
    kubectl
    kubectx

    # other packages
    zellij
    eva
    curl
    openssh
    flyctl
    direnv
    xsel
    navi
    xxh
    file
    gnupg
    watchexec
    rainfrog
    redis
    pre-commit
    protobuf
    atlas
    typos
    pgcli
    opkssh
    eksctl
    _1password-cli
    aws-sso-cli
  ];

  programs.bat = {
    # enable = true;
    config = {
      theme = "ansi";
    };
  };
}
