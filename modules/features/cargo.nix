{
  config,
  pkgs,
  lib,
  ...
}:
let
  inherit (pkgs.stdenv) isDarwin;
  home = config.home.homeDirectory;
  # rustup stable toolchain for the host triple.
  #
  # The Nix-provided `cargo` (packages.nix) mixes rustc versions within a single
  # build — proc-macro crates compile with a different rustc than library crates,
  # producing E0514 "crate compiled by an incompatible version of rustc". Pinning
  # build.rustc to one rustup toolchain binary (bypassing the rustup shim's
  # per-invocation resolution) makes cargo use a single rustc consistently.
  #
  # The final link also needs Apple clang as the linker driver so libc++ and
  # libiconv resolve via the macOS SDK; Nix's GCC sysroot lacks them.
  #
  # hostPlatform.rust.rustcTarget is the rustc-style triple (aarch64-apple-darwin),
  # not the Apple-style hostPlatform.config (arm64-apple-darwin) — both the
  # rustup toolchain dir and cargo's [target] key use the rustc form.
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

        # [env] is read by cargo from this file, independent of the shell
        # environment — unlike packages.nix's sessionVariables, which a
        # non-interactive process (e.g. an agent's bash tool) may not have
        # sourced. force overrides any CC/CXX already in the environment so
        # the `cc` crate always uses Apple clang (correct libc++ ABI, macOS
        # framework headers).
        [env]
        CC = { value = "/usr/bin/clang", force = true }
        CXX = { value = "/usr/bin/clang++", force = true }
      '';
    };
  };
}
