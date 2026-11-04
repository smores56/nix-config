{ pkgs, lib, ... }:
{
  programs = {
    bat.enable = true;
  };

  home = {
    sessionVariables = {
      DISABLE_NIX_SHELL_WELCOME = 1;
    }
    // lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
      # Apple clang for native builds outside cargo (uv, node-gyp, autotools); Nix's GCC sysroot lacks
      # macOS framework headers and its libstdc++ ABI mismatches libc++ crates.
      CC = "/usr/bin/clang";
      CXX = "/usr/bin/clang++";
    };

    packages =
      with pkgs;
      [
        eza
        fd
        ripgrep
        television

        jq
        curl
        sd
        zip
        unzip

        just

        dua
        bottom

        uv

        cbonsai

        bitwarden-cli
      ]
      ++ lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
        libiconv
        apple-sdk_15
      ]
      ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [ concord ];
  };
}
