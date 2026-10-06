{
  config,
  pkgs,
  ...
}:
let
  workflow = import ../../lib/repo-workflow.nix {
    inherit config pkgs;
    inherit (pkgs) lib;
  };
in
{
  home.packages = [
    workflow.repos
    workflow.worktrees
  ];

  home.file = {
    ".config/television/cable/repos.toml".source = ./repos.toml;
    ".config/television/cable/worktrees.toml".source = ./worktrees.toml;
  };

  dotfiles.shellAbbrs = {
    r = "pick repos c";
    w = "pick worktrees c";
    wg = "repos get";
    wn = "worktrees new";
    wp = "worktrees prune";
    wl = "worktrees list";
  };
}
