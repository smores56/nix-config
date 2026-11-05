# `vault <cmd>`: unlock the Cryptomator vault for exactly one command. Plaintext exists only in a
# temporary mount that is unmounted on exit; agent-sandbox masks ~/Sync (which holds the vault),
# and the server never unlocks anything.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (pkgs.stdenv.hostPlatform) isDarwin;

  # Linux uses the FUSE mounter; its WebDAV ones need a GIO session and are slower. macOS uses
  # fuse-t (a brew cask), which needs no kernel extension.
  mounter =
    if isDarwin then
      "org.cryptomator.frontend.fuse.mount.FuseTMountProvider"
    else
      "org.cryptomator.frontend.fuse.mount.LinuxFuseMountProvider";

  # nixpkgs limits cryptomator-cli to Linux, but its jar bundles the fuse-t provider and builds
  # unchanged on darwin.
  cryptomatorCli = pkgs.cryptomator-cli.overrideAttrs (old: {
    meta = old.meta // {
      platforms = old.meta.platforms ++ lib.platforms.darwin;
    };
  });

  platformHalf = if isDarwin then ./vault-darwin.sh else ./vault-linux.sh;

  script =
    builtins.replaceStrings
      [ "@VAULT@" "@MOUNTER@" "@PLATFORM@" ]
      [
        (lib.escapeShellArg "${config.home.homeDirectory}/Sync/vault")
        (lib.escapeShellArg mounter)
        (builtins.readFile platformHalf)
      ]
      (builtins.readFile ./vault.sh);

  vault = pkgs.writeShellApplication {
    name = "vault";
    runtimeInputs = [
      cryptomatorCli
      pkgs.coreutils
    ]
    ++ lib.optionals (!isDarwin) [
      pkgs.fuse3
      pkgs.util-linux
    ];
    text = script;
  };
in
{
  home.packages = [ vault ];
}
