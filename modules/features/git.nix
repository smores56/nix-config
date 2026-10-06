{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles;

  inherit (cfg) work;

  # GitHub owners are case-insensitive but hasconfig's wildmatch is not, so
  # spell every letter as a [xX] class.
  caseless =
    s:
    lib.concatMapStrings (
      c: if lib.toLower c != lib.toUpper c then "[${lib.toLower c}${lib.toUpper c}]" else c
    ) (lib.stringToCharacters s);
  # Every remote spelling of a github.com owner that git, gh and hand-pasted
  # URLs produce. Prefixes are explicit: a `*github.com` wildcard would also
  # match lookalike hosts.
  ownerRemotes =
    owner:
    let
      o = caseless owner;
    in
    [
      "git@github.com:${o}/**"
      "git@github.com:/${o}/**"
      "github.com:${o}/**"
      "ssh://git@github.com/${o}/**"
      "ssh://git@github.com:*/${o}/**"
      "ssh://github.com/${o}/**"
      "https://github.com/${o}/**"
      "https://*@github.com/${o}/**"
    ];
  # Keyed on the remote URL (not the checkout path) so clones, worktrees and
  # checkouts anywhere get it; hasconfig is evaluated during `git clone` too.
  # Any matching remote applies, so a fork with a work `upstream` is a work
  # repo. An included file must not set remote URLs (git refuses that).
  ownerIncludes =
    owner: settings:
    let
      path = pkgs.writeText "git-${lib.strings.sanitizeDerivationName owner}" (
        lib.generators.toGitINI settings
      );
    in
    map (url: {
      condition = "hasconfig:remote.*.url:${url}";
      inherit path;
    }) (ownerRemotes owner);

  # Read by `worktrees new`. Every key is always written (null unticketed as
  # empty, meaning "ticket required") so an owner include fully replaces the
  # global scheme instead of inheriting parts of it.
  branchSettings = naming: {
    branchTemplate = naming.template;
    branchTemplateUnticketed = toString naming.unticketed;
    inherit (naming) ticketPattern;
  };

  workIncludes = ownerIncludes work.githubOwnerGlob {
    user = {
      inherit (work) email;
      signingkey = "${work.sshKey}.pub";
    };
    core.sshCommand = "ssh -F ${work.sshConfig}";
    smores = {
      inherit (work) flow;
    }
    // branchSettings work.branchNaming;
  };
  # Only repos the personal account owns land directly on main; third-party
  # checkouts get no flow at all.
  personalIncludes = ownerIncludes cfg.githubUser { smores.flow = "direct"; };
  # Signatures only verify against keys listed here. Built from the local
  # .pub files rather than committed keys because personal keys differ per
  # machine; rerun `ssh-allowed-signers` after adding a key.
  allowedSigners = "~/.ssh/allowed_signers";
  allowedSignersWriter = pkgs.writeShellApplication {
    name = "ssh-allowed-signers";
    text = ''
      out=${lib.replaceStrings [ "~" ] [ "$HOME" ] allowedSigners}
      # No ~/.ssh yet (fresh host) means no keys to verify against.
      [ -d "$(dirname "$out")" ] || exit 0
      tmp=$(mktemp "$out.XXXXXX")
      entry() {
        # principal, git-only namespace, then key type and body (no comment)
        if [ -f "$2" ]; then
          # read fails at EOF without a trailing newline but still fills
          # the fields, which hand-pasted .pub files often lack
          read -r type body _ <"$2" || [ -n "''${type:-}" ]
          printf '%s namespaces="git" %s %s\n' "$1" "$type" "$body"
        fi
      }
      {
        entry ${lib.escapeShellArg cfg.email} "$HOME/.ssh/id_personal.pub"
        entry ${lib.escapeShellArg work.email} "${lib.replaceStrings [ "~" ] [ "$HOME" ] work.sshKey}.pub"
      } >"$tmp"
      mv "$tmp" "$out"
    '';
  };

  hunk = pkgs.writeShellScriptBin "hunk" ''
    export PATH="${pkgs.nodejs_24}/bin:$PATH"
    exec npx hunkdiff "$@"
  '';
in
{
  home.activation.sshAllowedSigners = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    $DRY_RUN_CMD ${lib.getExe allowedSignersWriter}
  '';

  home.packages = with pkgs; [
    allowedSignersWriter
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
          gpg.ssh.allowedSignersFile = allowedSigners;
          user.signingkey = "~/.ssh/id_personal.pub";
          fetch.prune = true;
          # Repo tooling reads smores.* instead of re-deriving the identity
          # from the remote.
          smores = branchSettings cfg.branchNaming;
        }
      ];
    };

    # `includes` render after `settings`, so the owner values win; an
    # includeIf inside `settings` sorts before [user] and loses to it. Work
    # comes last so a mixed personal/work repo is a work repo.
    git.includes = personalIncludes ++ workIncludes;

    lazygit.enable = true;
  };
}
