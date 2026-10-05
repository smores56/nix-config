{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles;

  inherit (cfg) work;

  # Work identity for repos whose remote is under a work GitHub owner. Keyed
  # on the remote URL (not the checkout path) so clones, worktrees and
  # checkouts anywhere get it; hasconfig is evaluated during `git clone` too.
  # The included file must not set remote URLs (git refuses that).
  workInclude = pkgs.writeText "git-work" (
    lib.generators.toGitINI {
      user = {
        inherit (work) email;
        signingkey = "~/.ssh/id_work.pub";
      };
      core.sshCommand = "ssh -F ~/.ssh/config.work";
      smores = {
        inherit (work) branchPrefix flow;
      };
    }
  );
  workRemotes = [
    "git@github.com:${work.githubOwnerGlob}/**"
    "ssh://git@github.com/${work.githubOwnerGlob}/**"
    "https://github.com/${work.githubOwnerGlob}/**"
  ];
  hunk = pkgs.writeShellScriptBin "hunk" ''
    export PATH="${pkgs.nodejs_24}/bin:$PATH"
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
    lazyjj
    hunk
  ];

  home.file.".gitignore".text = ''
    .worktrees/
    **/.claude/settings.local.json
  '';

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

      settings = lib.mkMerge [
        {
          user = {
            name = "Sam Mohr";
            inherit (cfg) email;
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
          user.signingkey = "~/.ssh/id_personal.pub";
          fetch.prune = true;
          # Repo tooling (worktrees new, agent context) reads these instead
          # of re-deriving the identity from the remote.
          smores = {
            inherit (cfg) branchPrefix;
            flow = "direct";
          };
        }
      ];
    };

    # `includes` render after `settings`, so the work values win; an
    # includeIf inside `settings` sorts before [user] and loses to it.
    git.includes = map (url: {
      condition = "hasconfig:remote.*.url:${url}";
      path = workInclude;
    }) workRemotes;

    lazygit.enable = true;
  };
}
