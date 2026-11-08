{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.user;
  colors = config.lib.stylix.colors;
  # A subtle diff tint over base00; delta has no alpha colors.
  blend =
    from: to: pct:
    let
      f = lib.fromHexString from;
      t = lib.fromHexString to;
      mix = a: b: builtins.div (a * (100 - pct) + b * pct) 100;
      channel =
        n:
        let
          h = lib.toHexString n;
        in
        if builtins.stringLength h == 1 then "0${h}" else h;
      r = mix (builtins.div f 65536) (builtins.div t 65536);
      g = mix (builtins.div (f - 65536 * builtins.div f 65536) 256) (
        builtins.div (t - 65536 * builtins.div t 65536) 256
      );
      b = mix (f - 256 * builtins.div f 256) (t - 256 * builtins.div t 256);
    in
    "#${channel r}${channel g}${channel b}";
  secretPath = import ../lib/secret-path.nix config;

  inherit (cfg) work;

  # Each GitHub account signs with its own sops key (modules/lib/signing-keys.nix): plain files,
  # so no agent, wrapper or PIN, and a host signs whether or not anyone is connected.
  sopsSecrets = config.sops.secrets or { };
  personalSigningKey = secretPath "github-personal-signing-key";

  # GitHub owners are case-insensitive but hasconfig's wildmatch is not, so
  # spell every letter as a [xX] class.
  caseless =
    s:
    lib.concatMapStrings (
      c: if lib.toLower c != lib.toUpper c then "[${lib.toLower c}${lib.toUpper c}]" else c
    ) (lib.stringToCharacters s);
  # Every remote spelling of a github.com owner; prefixes are explicit since `*github.com` would match lookalike hosts.
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
  # Keyed on the remote URL, not the checkout path, so clones and worktrees anywhere match
  # (hasconfig is evaluated during `git clone` too). Any matching remote applies: a fork with a
  # work `upstream` is a work repo. An included file must not set remote URLs.
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

  # Read by `worktrees new`. Every key is always written (unticketed as empty = "ticket required")
  # so an owner include fully replaces the global scheme.
  branchSettings = naming: {
    branchTemplate = naming.template;
    branchTemplateUnticketed = toString naming.unticketed;
  };

  workSettings = {
    user = {
      inherit (work) email;
    }
    # The work key is deployed only where the work account's bundle lives;
    # elsewhere a work commit falls back to the personal key.
    // lib.optionalAttrs (sopsSecrets ? github-work-signing-key) {
      signingkey = secretPath "github-work-signing-key";
    };
    smores = {
      inherit (work) flow;
    }
    // branchSettings work.branchNaming;
  };
  # One include per listed owner, never a pattern: an org anyone can register
  # must not pick up the work identity, token or signing key.
  workIncludes = lib.concatMap (owner: ownerIncludes owner workSettings) work.githubOwners;
  # Only repos the personal account owns get the local flow; the signing key rides along so the include is self-contained.
  personalIncludes = ownerIncludes cfg.githubUser {
    smores.flow = "local";
    user.signingkey = personalSigningKey;
  };

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
        git_protocol = "https";
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
            # bat's Stylix theme; home-manager rebuilds bat's cache with it.
            syntax-theme = "base16-stylix";
            minus-style = "syntax ${blend colors.base00 colors.base08 15}";
            plus-style = "syntax ${blend colors.base00 colors.base0B 15}";
            minus-emph-style = "syntax ${blend colors.base00 colors.base08 30}";
            plus-emph-style = "syntax ${blend colors.base00 colors.base0B 30}";
            line-numbers-minus-style = "#${colors.base08}";
            line-numbers-plus-style = "#${colors.base0B}";
            line-numbers-zero-style = "#${colors.base03}";
            file-style = "#${colors.base0D} bold";
            file-decoration-style = "#${colors.base0D} ul";
            hunk-header-decoration-style = "#${colors.base0D} ul";
            commit-style = "#${colors.base0E} bold";
            commit-decoration-style = "#${colors.base0E}";
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
