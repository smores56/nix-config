{ config, pkgs, ... }:
let
  cfg = config.dotfiles;
  hunk = pkgs.writeShellScriptBin "hunk" ''
    export PATH="${pkgs.nodejs}/bin:$PATH"
    exec npx hunkdiff "$@"
  '';
in
{
  home.packages = with pkgs; [
    gnupg
    delta
    git-lfs
    difftastic
    jujutsu
    hunk
  ];

  programs = {
    gh = {
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

    git = {
      enable = true;

      settings = {
        user = {
          name = "Sam Mohr";
          email = cfg.email;
        };
        core = {
          excludesFile = "~/.gitignore";
          pager = "delta";
        };
        push.default = "simple";
        pull.rebase = "true";
        init.defaultBranch = "main";
        diff.colorMoved = "default";
        delta = {
          navigate = true;
          line-numbers = true;
        };
        difftool = {
          prompt = false;
          difftastic.cmd = "difft \"$LOCAL\" \"$REMOTE\"";
        };
        pager = {
          diff = "delta";
          log = "delta";
          reflog = "delta";
          show = "delta";
        };
        interactive.diffFilter = "delta --color-only";
        safe.directory = "*";
        commit.gpgsign = true;
        gpg.format = "ssh";
        fetch.prune = true;
      };
    };

    lazygit.enable = true;
  };
}
