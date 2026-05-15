{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles;
  wcbPrefix =
    "${cfg.branchPrefix}/" + lib.optionalString (cfg.ticketPrefix != null) "${cfg.ticketPrefix}-";
in
{
  home.packages = with pkgs; [
    ghq
    worktrunk
  ];

  programs.git.settings.ghq.root = cfg.codeRoot;

  home.file = {
    ".config/worktrunk/config.toml".source = ./repos/worktrunk.toml;
    ".config/television/cable/repos.toml".source = ./repos/tv-repos.toml;
    ".config/television/cable/worktrees.toml".source = ./repos/tv-worktrees.toml;
  };

  programs.fish = {
    interactiveShellInit = ''
      wt config shell init fish | source
      abbr -a wcb --set-cursor "wt switch --create ${wcbPrefix}%"
    '';

    shellAbbrs = {
      ws = "wt switch";
      wc = "wt switch --create";
      wm = "wt merge";
      wx = "wt remove";
      wl = "wt list";
    };

    functions = {
      r = {
        description = "Fuzzy-pick a ghq-managed repo and cd in (interactive)";
        body = ''
          set -l selected (tv repos)
          test -n "$selected"; and cd -- "$selected"
        '';
      };
      w = {
        description = "Fuzzy-pick a worktree of the current repo and cd in (interactive)";
        body = ''
          set -l selected (tv worktrees)
          test -n "$selected"; and cd -- "$selected"
        '';
      };
    };
  };
}
