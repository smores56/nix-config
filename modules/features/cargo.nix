{
  config,
  pkgs,
  lib,
  ...
}:
let
  inherit (pkgs.stdenv.hostPlatform) isDarwin;
  home = config.home.homeDirectory;
  # rustup's cargo shim resolves the toolchain per invocation, mixing rustc versions in one build
  # (proc-macro crates vs library crates: E0514 "incompatible version of rustc"); pinning
  # build.rustc to one toolchain binary bypasses it. The link needs Apple clang as driver for
  # libc++/libiconv from the macOS SDK. rustcTarget is the rustc-style triple
  # (aarch64-apple-darwin), which rustup's toolchain dir and cargo's [target] key use.
  triple = pkgs.stdenv.hostPlatform.rust.rustcTarget;
  rustupStable = "${home}/.rustup/toolchains/stable-${triple}";
in
{
  config = lib.mkIf isDarwin {
    home.file.".cargo/config.toml" = {
      force = true;
      text = ''
        [build]
        rustc = "${rustupStable}/bin/rustc"
        rustdoc = "${rustupStable}/bin/rustdoc"

        [target.${triple}]
        rustflags = ["-C", "linker=/usr/bin/clang"]

        # [env] is read from this file regardless of shell, unlike packages.nix's sessionVariables that
        # non-interactive processes may lack. force makes the `cc` crate always use Apple clang.
        [env]
        CC = { value = "/usr/bin/clang", force = true }
        CXX = { value = "/usr/bin/clang++", force = true }
      '';
    };
  };
}
