{ pkgs, polarity, ... }: {
  home.packages = with pkgs; [
    delta
    gh
    mercurial
    git-lfs
    gitui
  ];

  programs.git = {
    enable = true;

    userName = "Sam Mohr";
    userEmail = "sam@sammohr.dev";

    extraConfig = {
      core = {
        excludesFile = "$HOME/.gitignore";
        pager = "delta";
      };
      push = {
        default = "simple";
      };
      pull = {
        rebase = "true";
      };
      init = {
        defaultBranch = "main";
      };
      diff = {
        colorMoved = "default";
      };
      delta = {
        navigate = true;
        line-numbers = true;
      };
      pager = {
        diff = "delta";
        log = "delta";
        reflog = "delta";
        show = "delta";
      };
      interactive = {
        diffFilter = "delta --color-only";
      };
      safe = {
        directory = "*";
      };
      commit = {
        gpgsign = true;
      };
    };
  };

  programs.lazygit = {
    enable = true;

    settings = {
      git.paging = {
        colorArg = "always";
        pager = "delta --paging=never --${if polarity == "light" then "light" else "dark"}";
      };
      gui.theme = {
        lightTheme = polarity == "light";
        selectedLineBgColor = [ "underline" ];
        selectedRangeBgColor = [ "underline" ];
      };
    };
  };
}
