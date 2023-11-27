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
    # rust tools
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
    typst
    licensor
    terminal-typeracer
    typst

    # go tools
    gum
    glow
    fzf

    # languages
    go
    python3Full
    cargo
    rustc
    yarn

    # fun stuff
    cbonsai
    musikcube

    # other packages
    jq
    curl
    openssh
    zip
    unzip
    flyctl
    comma
    file
    direnv
    xsel
  ];

  programs.bat = {
    enable = true;
    config = {
      theme = "ansi";
    };
  };
}
