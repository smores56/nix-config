{ pkgs, displayManager, ... }:
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

  home.packages =
    with pkgs;
    [
      # exploration
      zoxide
      eza
      fd
      ripgrep
      glow
      fzf
      jq
      delta
      television

      # AI tools
      claude-code

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
      deno
      yarn
      nodePackages.pnpm
      erg
      typst
      idris2
      fnm
      zig

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
      # terminal-typeracer

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
    ]
    ++ (
      if pkgs.stdenv.isLinux && displayManager != null then
        [
          wl-clipboard
        ]
      else
        [ ]
    )
    ++ (
      if pkgs.stdenv.isDarwin then
        [
          ngrok
          graphviz
          watchman
          grpcurl
          grpcui
          bazelisk
          buildifier
          flyway
        ]
      else
        [ ]
    );

  programs.bat = {
    enable = true;
    config = {
      theme = "ansi";
    };
  };
}
