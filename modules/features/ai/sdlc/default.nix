{ pkgs, ... }:
{
  home.packages = [
    (import ../../../lib/sdlc.nix { inherit pkgs; })
    pkgs.revdiff
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
