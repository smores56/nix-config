{ pkgs, ... }: {
  imports = [
    ./editor.nix
    ./git.nix
    ./lf.nix
    ./zellij.nix
  ];

  home.packages = with pkgs; [
    jq
    curl
    openssh
    # TODO: https://github.com/willeccles/f # Simple sysfetch
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
