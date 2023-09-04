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

    zoxide
    exa
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

    gum
    glow
    fzf

    go
    python3
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
