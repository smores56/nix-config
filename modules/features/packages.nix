{ pkgs, lib, ... }:
{
  # Workaround: Stylix's opencode module defines programs.opencode.tui even
  # with targets.opencode disabled and no opencode installed. Declare the
  # option so evaluation succeeds. (We do not use opencode.)
  options.programs.opencode.tui = lib.mkOption {
    type = lib.types.anything;
    default = { };
  };
  config = {
    programs = {
      bat.enable = true;
      fzf.enable = true;
      k9s.enable = true;
    };

    home = {
      sessionVariables = {
        DISABLE_NIX_SHELL_WELCOME = 1;
      }
      // lib.optionalAttrs pkgs.stdenv.isDarwin {
        # Use Apple's clang for C compilation — Nix's GCC sysroot lacks macOS
        # framework headers (CoreServices, Security, etc.) needed by native deps.
        CC = "/usr/bin/clang";
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
          openssh

          # data interaction
          jq
          eva
          curl
          sd
          ouch
          zip
          unzip
          lazysql

          # environment management
          awscli2
          aws-sso-cli
          _1password-cli
          just
          zellij

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
        ++ lib.optionals pkgs.stdenv.isDarwin [
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
          kubernetes-helm
          kubectl
          kubectx
        ]
        ++ lib.optionals pkgs.stdenv.isLinux [
          bubblewrap
          concord
          odin
        ];
    };
  };
}
