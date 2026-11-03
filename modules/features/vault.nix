# `vault <cmd>`: unlock the Cryptomator vault for exactly one command.
#
# Plaintext exists only inside that session. The helper mounts into a temporary
# directory, runs the command there, and unmounts on exit, so nothing stays
# mounted between uses; agent-sandbox masks ~/Sync (which contains the vault) for
# the whole time, and the server itself never unlocks anything.
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
