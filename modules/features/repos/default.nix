{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles;
  waPrefix =
    "${cfg.branchPrefix}/" + lib.optionalString (cfg.ticketPrefix != null) "${cfg.ticketPrefix}-";
in
{
  home.packages = with pkgs; [
    ghq
    worktrunk
  ];

  programs.git.settings.ghq.root = cfg.codeRoot;

  home.file = {
    ".config/worktrunk/config.toml".source = ./worktrunk.toml;
    ".config/television/cable/repos.toml".source = ./tv-repos.toml;
    ".config/television/cable/worktrees.toml".source = ./tv-worktrees.toml;
  };

  programs.fish = {
    interactiveShellInit = ''
      wt config shell init fish | source
      abbr -a wa --set-cursor "wt switch --create ${waPrefix}%"
    '';

    shellAbbrs = {
      r = "tv repos | read -l s; and c $s";
      w = "tv worktrees | read -l s; and c $s";
      wc = "wt switch --create";
      wm = "wt merge";
      wx = "wt remove";
      wl = "wt list";
    };
  };
}
