{ pkgs, ... }:
let
  sdlc = pkgs.writeShellScriptBin "sdlc" ''
    exec ${pkgs.python3}/bin/python3 ${./sdlc_issues.py} "$@"
  '';
in
{
  home.packages = [ sdlc ];

  home.file.".config/television/cable/features.toml".source = ./features.toml;

  user.shellAbbrs = {
    s = "pick features c";
    sl = "sdlc list";
    sa = "sdlc approve --pick";
    sn = "sdlc next --pick";
  };
}
