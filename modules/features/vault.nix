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
  # The Linux FUSE mounter; the WebDAV ones need a GIO session and are slower.
  mounter = "org.cryptomator.frontend.fuse.mount.LinuxFuseMountProvider";

  script =
    builtins.replaceStrings
      [ "@VAULT@" "@MOUNTER@" ]
      [
        (lib.escapeShellArg "${config.home.homeDirectory}/Sync/vault")
        (lib.escapeShellArg mounter)
      ]
      (builtins.readFile ./vault.sh);

  vault = pkgs.writeShellApplication {
    name = "vault";
    runtimeInputs = [
      pkgs.cryptomator-cli
      pkgs.fuse3
      pkgs.coreutils
      pkgs.util-linux
    ];
    text = script;
  };
in
lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
  home.packages = [ vault ];
}
