{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.user;

  inherit (cfg) work;

  # Each GitHub account signs with its own sops key (modules/lib/signing-keys.nix):
  # /run/secrets on NixOS, the home's sops path on Darwin. Plain files, so git
  # needs no agent, wrapper or PIN, and a host signs whether or not anyone is
  # connected.
  sopsSecrets = config.sops.secrets or { };
  signingKeyPath = name: sopsSecrets.${name}.path or "/run/secrets/${name}";
  personalSigningKey = signingKeyPath "github-personal-signing-key";

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
  };

  workIncludes = ownerIncludes work.githubOwnerGlob (
    {
      user = {
        inherit (work) email;
      }
      # The work key is deployed only where the work account's bundle lives;
      # elsewhere a work commit falls back to the personal key.
      // lib.optionalAttrs (sopsSecrets ? github-work-signing-key) {
        signingkey = signingKeyPath "github-work-signing-key";
      };
      smores = {
        inherit (work) flow;
      }
      // branchSettings work.branchNaming;
    }
    // lib.optionalAttrs config.machine.workHost {
      core.sshCommand = "ssh -F ${work.sshConfig}";
    }
    // lib.optionalAttrs (!config.machine.workHost) {
      # Other hosts have no work private key; use HTTPS + the work PAT. The
      # owner-selecting credential helper supplies the token.
      url."https://github.com/".insteadOf = [
        "git@github.com:"
        "ssh://git@github.com/"
      ];
    }
  );
  # Only repos the personal account owns get the local flow; third-party
  # checkouts get no flow at all.
  personalIncludes = ownerIncludes cfg.githubUser { smores.flow = "local"; };

in
{
  home.packages = with pkgs; [
    delta
    git-lfs
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
    };

    git = {
      enable = true;

      settings = lib.mkMerge [
        {
          user = {
            name = "Sam Mohr";
            inherit (cfg) email;
            signingkey = personalSigningKey;
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
