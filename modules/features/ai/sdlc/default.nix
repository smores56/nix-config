{ pkgs, ... }:
{
  home.packages = [
    (pkgs.writeShellScriptBin "sdlc" ''
      exec ${pkgs.python3}/bin/python3 ${./sdlc_issues.py} "$@"
    '')
    pkgs.tuicr
  ];

  user.shellAbbrs = {
    s = "sdlc ui";
    ss = "sdlc ui show";
    st = "sdlc ui status";
    sl = "sdlc list";
    sr = "sdlc ui review";
    sc = "sdlc ui comment";
    sn = "sdlc ui next";
    sa = "sdlc ui approve";
  };
}
