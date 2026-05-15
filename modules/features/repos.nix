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
    ".config/worktrunk/config.toml".source = ./repos/worktrunk.toml;
    ".config/television/cable/repos.toml".source = ./repos/tv-repos.toml;
  };

  programs.fish = {
    interactiveShellInit = ''
      wt config shell init fish | source
      abbr -a wa --set-cursor "wt switch --create ${waPrefix}%"
    '';

    shellAbbrs = {
      ws = "wt switch";
      wc = "wt switch --create";
      wm = "wt merge";
      wx = "wt remove";
      wl = "wt list";
    };

    functions.r = {
      description = "Fuzzy-pick a ghq-managed repo and cd in (interactive)";
      body = ''
        set -l selected (tv repos)
        test -n "$selected"; and cd -- "$selected"
      '';
    };
  };
}
