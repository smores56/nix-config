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
    goose-cli
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
    python3Full
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
    (pkgs.fenix.complete.withComponents [
      "cargo"
      "clippy"
      "rust-src"
      "rustc"
      "rustfmt"
    ])

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
    oxker
    kubernetes-helm
    kubectl

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
  ];

  # programs.bat = {
  #   enable = true;
  #   config = {
  #     theme = "ansi";
  #   };
  # };
}
