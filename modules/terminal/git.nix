{ pkgs, polarity, ... }:
{
  home.packages = with pkgs; [
    delta
    gh
    git-lfs
    gitui
    difftastic
    jujutsu
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
      difftool = {
        prompt = false;
        difftastic = {
          cmd = "difft \"$LOCAL\" \"$REMOTE\"";
        };
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
        # gpgsign = true;
      };
      # gpg.format = "ssh";
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
