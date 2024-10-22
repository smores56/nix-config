{ pkgs, polarity, ... }: {
  home.packages = with pkgs; [
    delta
    gh
    mercurial
    git-lfs
    gitui
    difftastic
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
        tool = "difftastic";
        external = "difft";
      };
      difftool = {
        prompt = false;
        difftastic = {
          cmd = "difft \"$LOCAL\" \"$REMOTE\"";
        };
      };
      pager = {
        difftool = true;
      };
      interactive = {
        diffFilter = "difft --color-only";
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
        externalDiffCommand = "difft --color=always";
      };
      gui.theme = {
        lightTheme = polarity == "light";
        selectedLineBgColor = [ "underline" ];
        selectedRangeBgColor = [ "underline" ];
      };
    };
  };
}
