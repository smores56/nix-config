# `sudo vault`: open the vault for one foreground session.
#
# The store is owned by the `vault` user and the human's uid has no access to it at rest (see
# modules/nixos/vault-sync.nix). bindfs maps that user to the caller and mounts
# the tree at ~/.local/share/vault, so editors and file managers work normally
# for the session. Root is required, which on the NixOS hosts means the
# YubiKey-gated sudo, and the mount lives exactly as long as the foreground process.
{
  pkgs,
  ...
}:
let
  script =
    builtins.replaceStrings
      [ "@STORE@" "@PLATFORM@" ]
      [ "/var/lib/data/vault" (builtins.readFile ./vault-linux.sh) ]
      (builtins.readFile ./vault.sh);

  vault = pkgs.writeShellApplication {
    name = "vault";
    runtimeInputs = [
      pkgs.bindfs
      pkgs.coreutils
      pkgs.glibc.bin # getent, for home_of
      pkgs.sudo
      pkgs.util-linux
    ];
    text = script;
  };
in
{
  home.packages = [ vault ];
}
