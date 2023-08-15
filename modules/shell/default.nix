{ pkgs, ... }: {
  imports = [
    ./fish
    ./editor.nix
    ./git.nix
    ./lf.nix
    ./zellij.nix
  ];

  home.sessionVariables = {
    GUM_CHOOSE_CURSOR_FOREGROUND = 3;
    # LS_COLORS (cat ~/.config/fish/ls-colors.txt)
  };

  home.packages = with pkgs; [
    jq
    curl
    openssh
    zip
    unzip
    flyctl

    zoxide
    exa
    ripgrep
    sd
    zellij
    delta
    bat
    fd
    dua
    ouch
    bottom
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
