{
  config,
  pkgs,
  ...
}:
let
  workflow = import ../../lib/repo-workflow.nix {
    inherit config pkgs;
    lib = pkgs.lib;
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

  programs.fish.shellAbbrs = {
    r = "tv repos | read -l path; and c $path";
    w = "tv worktrees | read -l path; and c $path";
    wg = "repos get";
    wn = "worktrees new";
    wp = "worktrees prune";
    wl = "worktrees list";
  };
}
