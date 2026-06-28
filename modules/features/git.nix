{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles;
  hasWorkGithubOrgs = cfg.workGithubOrgs != [ ];

  hunk = pkgs.writeShellScriptBin "hunk" ''
    export PATH="${pkgs.nodejs}/bin:$PATH"
    exec npx hunkdiff "$@"
  '';

  githubSsh = pkgs.writeShellScriptBin "git-github-ssh" ''
    is_github=false
    key="$HOME/.ssh/id_personal.pub"

    for arg in "$@"; do
      case "$arg" in
        github.com|git@github.com)
          is_github=true
          ;;
      esac
    done

    if $is_github; then
      for org in ${lib.escapeShellArgs cfg.workGithubOrgs}; do
        for arg in "$@"; do
          case "$arg" in
            *"$org"/*|*"$org":*)
              key="$HOME/.ssh/id_work.pub"
              ;;
          esac
        done
      done

      # Point IdentityFile at the .pub so ssh resolves the key via the
      # ssh-agent rather than the private key file (hidden inside smolvm).
      exec ${pkgs.openssh}/bin/ssh -F /dev/null -o "IdentityFile=$key" -o IdentitiesOnly=yes "$@"
    fi

    exec ${pkgs.openssh}/bin/ssh "$@"
  '';

  workGithubUrlRewrites = lib.listToAttrs (
    map (org: {
      name = "git@github.com:${org}/";
      value.insteadOf = [
        "https://github.com/${org}/"
      ];
    }) cfg.workGithubOrgs
  );
in
{
  home.packages =
    (with pkgs; [
      gnupg
      delta
      git-lfs
      difftastic
      jujutsu
      lazyjj
      hunk
    ])
    ++ lib.optionals hasWorkGithubOrgs [
      githubSsh
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
        }
        (lib.mkIf hasWorkGithubOrgs {
          core.sshCommand = "${githubSsh}/bin/git-github-ssh";
          url = workGithubUrlRewrites;
        })
      ];
    };

    lazygit.enable = true;
  };
}
