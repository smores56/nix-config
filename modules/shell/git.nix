{ pkgs, ... }: {
  home.packages = [
    pkgs.delta
    pkgs.gitAndTools.gh
  ];

  programs.git = {
    enable = true;

    userName = "Sam Mohr";
    userEmail = "sam@sammohr.dev";

    aliases = {
      prettylog = "...";
    };
    extraConfig = {
      core = {
        excludesFile = "$HOME/.gitignore";
        pager = "delta";
      };
      push = {
        default = "simple";
      };
      pull = {
        rebase = "false";
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
    };
  };

  programs.lazygit = {
    enable = true;

    settings = {
      os.editPreset = "helix";
      git.paging = {
        colorArg = "always";
        pager = "delta --paging=never --dark";
      };
      gui.theme = {
        lightTheme = false;
        selectedLineBgColor = [ "underline" ];
        selectedRangeBgColor = [ "underline" ];
      };
    };
  };
}
