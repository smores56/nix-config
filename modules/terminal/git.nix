{ pkgs, polarity, ... }:
{
  home.packages = with pkgs; [
    delta
    git-lfs
    difftastic
    jujutsu
  ];

  programs.gh = {
    enable = true;
    settings = {
      aliases = {
        co = "pr checkout";
        pv = "pr view";
      };
      editor = "hx";
      git_protocol = "ssh";
    };

    extensions = with pkgs; [
      gh-f
      gh-i
      gh-s
      gh-eco
      gh-dash
      gh-notify
    ];
  };

  programs.git = {
    enable = true;

    settings = {
      user = {
        name = "Sam Mohr";
        email = "sam@sammohr.dev";
      };
      core = {
        excludesFile = "~/.gitignore";
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
      git.pagers = [
        {
          colorArg = "always";
          pager = "delta --paging=never --${if polarity == "light" then "light" else "dark"}";
        }
      ];
      gui.theme = {
        lightTheme = polarity == "light";
        selectedLineBgColor = [ "underline" ];
        selectedRangeBgColor = [ "underline" ];
      };
    };
  };
}
