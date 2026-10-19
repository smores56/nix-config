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
        television

        # data interaction
        jq
        curl
        sd
        zip
        unzip

        # environment management
        just

        # monitoring
        dua
        bottom

        # ad-hoc Python
        uv

        # fun stuff
        cbonsai
      ]
      ++ lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
        libiconv
        apple-sdk_15
      ]
      ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [ concord ];
  };
}
