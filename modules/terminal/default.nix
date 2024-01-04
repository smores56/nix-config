{ pkgs, ... }: {
  imports = [
    ./shell
    ./editor
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
    erg
    typst
    terraform

    # fun stuff
    gum
    cbonsai
    musikcube
    terminal-typeracer
    jrnl

    # container tools
    k9s
    docker
    docker-compose
    oxker

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
    clipman
  ];

  programs.bat = {
    enable = true;
    config = {
      theme = "ansi";
    };
  };
}
