{ pkgs, ... }:
let
  # PATH bin so the brain skill can call it by name from any session.
  brainDigest = pkgs.writeShellScriptBin "brain-digest" ''
    exec ${pkgs.python3}/bin/python3 ${./brain-digest.py} "$@"
  '';
in
{
  config.home.packages = [ brainDigest ];
}
