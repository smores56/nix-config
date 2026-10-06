{ pkgs, lib, ... }:
{
  programs = {
    bat.enable = true;
    fzf.enable = true;
  };

  home = {
    sessionVariables = {
      DISABLE_NIX_SHELL_WELCOME = 1;
    }
    // lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
      # Apple clang for native builds run outside cargo (uv, node-gyp,
      # autotools); cargo's own CC/CXX live in ~/.cargo/config.toml. Nix's GCC
      # sysroot lacks macOS framework headers and its libstdc++ ABI mismatches
      # crates that link libc++.
      CC = "/usr/bin/clang";
      CXX = "/usr/bin/clang++";
    };

    packages =
      with pkgs;
      [
        # exploration
        eza
        fd
        ripgrep
        glow
        television

        # data interaction
        jq
        eva
        curl
        sd
        ouch
        zip
        unzip
        lazysql

        # documents
        poppler-utils

        # environment management
        _1password-cli
        just

        # networking
        tailscale

        # monitoring
        dua
        tokei
        bottom
        watchexec
        lsof

        # languages
        go
        uv
        python3
        deno
        bun
        nodejs_24
        typst
        cargo
        tree-sitter

        # compilation
        gcc
        pkg-config
        openssl.dev
        libiconv
        wabt
      ]
      ++ lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
        pkgs.apple-sdk_15
      ]
      ++ [

        # fun stuff
        cbonsai
        musikcube
        clock-rs
        ttyper

        # TUI utilities
        gum

        # container tools
        lazydocker
        docker-compose
      ]
      ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
        concord
        odin
      ];
  };
}
