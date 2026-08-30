{ pkgs, ... }:
let
  sdlcBin = pkgs.writeShellScriptBin "sdlc" ''
    exec ${pkgs.python3}/bin/python3 ${./sdlc.py} "$@"
  '';
in
{
  home.packages = [ sdlcBin ];
}
