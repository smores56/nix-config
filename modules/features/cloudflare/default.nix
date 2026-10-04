# cloudflare-sync: reconcile Cloudflare DNS + Access for the endpoints declared
# in `dotfiles.webProxy.services`. This home-side copy is the manual `--check`
# entry point; the systemd unit that actually applies state is
# `modules/nixos/cloudflare-sync.nix`, which reads the token at runtime from
# `dotfiles.webProxy.apiTokenFile` (0600, never in the store). See that module
# for provisioning and scope notes.
{
  lib,
  pkgs,
  ...
}:
let
  inherit (pkgs.stdenv) isLinux;
  cloudflare-sync = pkgs.writeShellScriptBin "cloudflare-sync" ''
    exec ${pkgs.python3}/bin/python3 ${./cloudflare_sync.py} "$@"
  '';
in
{
  config = lib.mkIf isLinux {
    home.packages = [ cloudflare-sync ];
  };
}
