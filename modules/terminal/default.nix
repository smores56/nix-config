{ pkgs, ... }: {
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
    delta

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

    # languages
    go
    python3Full
    cargo
    rustc
    yarn
    nodePackages.pnpm
    erg
    typst
    terraform
    gleam
    elixir
    erlang
    rebar3
    idris2
    fnm

    # compilation
    gcc
    pkg-config
    openssl.dev

    # fun stuff
    gum
    cbonsai
    musikcube
    # terminal-typeracer

    # container tools
    k9s
    docker
    docker-compose
    oxker
    kubernetes-helm
    kubectl

    # other packages
    zellij
    eva
    licensor
    curl
    openssh
    flyctl
    direnv
    xsel
    navi
    xxh
    file
    awscli2
    gnupg
  ] ++ (if pkgs.stdenv.isLinux then [
    pinentry
    wl-clipboard
  ] else [ ])
  ++ (if pkgs.stdenv.isDarwin then [
    ngrok
    graphviz
    gnupg
    watchman
    grpcurl
    grpcui
    bazelisk
    teleport
  ] else [ ]);

  programs.bat = {
    enable = true;
    config = {
      theme = "ansi";
    };
  };
}
