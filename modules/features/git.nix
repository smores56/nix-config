{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.user;

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
  };

  workIncludes = ownerIncludes work.githubOwnerGlob {
    user = {
      inherit (work) email;
    }
    // lib.optionalAttrs (!isLinux) {
      # The work Mac keeps its existing software-key signing path (T4).
      signingkey = "${work.sshKey}.pub";
    };
    core.sshCommand = "ssh -F ${work.sshConfig}";
    smores = {
      inherit (work) flow;
    }
    // branchSettings work.branchNaming;
  };
  # Only repos the personal account owns get the local flow; third-party
  # checkouts get no flow at all.
  personalIncludes = ownerIncludes cfg.githubUser { smores.flow = "local"; };

  inherit (pkgs.stdenv.hostPlatform) isLinux;
  isServer = builtins.elem "server" config.machine.profiles;

  # Git asks this for the key to sign with. On laptops the signing-only agent
  # holds the no-touch FIDO2 credentials; on smortress the forwarded login
  # agent holds the PIV keys. Pick the first key the agent offers that appears
  # in allowed_signers, so whichever key is inserted is used.
  signingKeyCommand = pkgs.writeShellApplication {
    name = "gpg-ssh-default-key";
    runtimeInputs = [
      pkgs.openssh
      pkgs.coreutils
      pkgs.gnugrep
    ];
    text = ''
      ${lib.optionalString (!isServer) ''
        export SSH_AUTH_SOCK="''${XDG_RUNTIME_DIR:?}/fido2-sign-agent"
      ''}
      ${lib.optionalString isServer ''
        [ -n "''${SSH_AUTH_SOCK:-}" ] || {
          echo "gpg-ssh-default-key: SSH_AUTH_SOCK is not set; reconnect or run the login hook" >&2
          exit 1
        }
      ''}
      allowed="$HOME/.config/ssh/allowed_signers"
      [ -r "$allowed" ] || exit 1
      keys=$(ssh-add -L 2>/dev/null) || exit 1
      while read -r type body _; do
        [ -n "''${type:-}" ] || continue
        if grep -qF -- "$type $body" "$allowed"; then
          printf 'key::%s %s\n' "$type" "$body"
          exit 0
        fi
      done <<<"$keys"
      exit 1
    '';
  };

  # gpg.ssh.program: on laptops, sign through the signing-only agent; on
  # smortress leave SSH_AUTH_SOCK alone so the forwarded PIV agent is used.
  sshKeygen = pkgs.writeShellApplication {
    name = "ssh-keygen-fido2";
    runtimeInputs = [ pkgs.openssh ];
    text = ''
      ${lib.optionalString (!isServer) ''
        export SSH_AUTH_SOCK="''${XDG_RUNTIME_DIR:?}/fido2-sign-agent"
      ''}
      exec ${pkgs.openssh}/bin/ssh-keygen "$@"
    '';
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
          gpg = {
            format = "ssh";
          }
          // lib.optionalAttrs isLinux {
            ssh = {
              program = lib.getExe sshKeygen;
              defaultKeyCommand = lib.getExe signingKeyCommand;
            };
          };
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
