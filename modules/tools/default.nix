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
  };

  home.packages = with pkgs; [
    jq
    curl
    openssh
    zip
    unzip
    flyctl
    comma
    file
    direnv
    cbonsai
    xsel

    zoxide
    eza
    ripgrep
    sd
    zellij
    delta
    fd
    dua
    ouch
    bottom
    tokei
    eva
    licensor
    terminal-typeracer
    typst

    gum
    glow
    fzf

    go
    python3Full
    cargo
    rustc
    yarn
  ];

  programs.bat = {
    enable = true;
    config = {
      theme = "ansi";
    };
  };
}
