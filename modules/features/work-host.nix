{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles;
  inherit (cfg.work) flatRepos githubOwnerGlob toolShell;
  hasFlat = cfg.workHost && flatRepos != null;
  orgPaths = lib.optionals hasFlat (map (org: "${cfg.codeRoot}/github.com/${org}") flatRepos.orgs);

  links = import ../lib/work-repo-links.nix { inherit pkgs; };
  linkArgs = lib.escapeShellArgs (
    [
      flatRepos.dir
      "${cfg.codeRoot}/github.com"
    ]
    ++ flatRepos.orgs
  );
  # This host's layout baked in, so `work-repo-links --migrate` needs no args.
  hostLinks = pkgs.writeShellScriptBin "work-repo-links" ''
    case "''${1-}" in
      "") exec ${lib.getExe links} ${linkArgs} ;;
      --migrate) exec ${lib.getExe links} --migrate ${linkArgs} ;;
      *) printf 'usage: work-repo-links [--migrate]\n' >&2; exit 2 ;;
    esac
  '';

  # git wildmatch (as used by the work includes) to a case-folded regex;
  # owner globs only use * and ?.
  globRegex =
    glob:
    lib.concatMapStrings (
      c:
      if c == "*" then
        ".*"
      else if c == "?" then
        "."
      else
        lib.escapeRegex c
    ) (lib.stringToCharacters (lib.toLower glob));
  outsideGlob = lib.filter (
    org: builtins.match (globRegex githubOwnerGlob) (lib.toLower org) == null
  ) (if flatRepos == null then [ ] else flatRepos.orgs);
in
lib.mkMerge [
  (lib.mkIf cfg.workHost {
    # Employer toolchains often pin Python through a non-Nix pyenv; init it
    # only where one is installed so repo .python-version venvs resolve.
    # --no-rehash keeps shell startup off pyenv's shim lock. With no pyenv
    # global set, bare python3 falls through to the Nix one.
    programs.fish.interactiveShellInit = lib.mkAfter ''
      if type -q pyenv
          pyenv init - --no-rehash fish | source
          if type -q pyenv-virtualenv-init
              pyenv virtualenv-init - fish | source
          end
      end
    '';
  })

  (lib.mkIf hasFlat {
    assertions = [
      {
        assertion = lib.hasPrefix "/" flatRepos.dir && !(lib.hasSuffix "/" flatRepos.dir);
        message = "dotfiles.work.flatRepos.dir must be an absolute path without a trailing slash: ${flatRepos.dir}";
      }
      {
        # A linked org outside the glob would sit in the work folder but
        # commit with the personal identity.
        assertion = outsideGlob == [ ];
        message = "dotfiles.work.flatRepos.orgs not matched by githubOwnerGlob ${githubOwnerGlob}: ${lib.concatStringsSep ", " outsideGlob}";
      }
      {
        # The org paths become links to dir; dir inside one would loop.
        assertion = lib.all (p: flatRepos.dir != p && !(lib.hasPrefix "${p}/" flatRepos.dir)) orgPaths;
        message = "dotfiles.work.flatRepos.dir must not be inside a linked org path: ${flatRepos.dir}";
      }
    ];

    # Employer tooling sees one flat folder while every checkout stays
    # reachable at <codeRoot>/github.com/<owner>/<repo>.
    home.activation.workRepoLinks = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run ${lib.getExe hostLinks}
    '';
    home.packages = [ hostLinks ];

    # Fish only: the tooling's own zsh rc sets it there.
    home.sessionVariables = lib.optionalAttrs (flatRepos.envVar != null) {
      ${flatRepos.envVar} = flatRepos.dir;
    };

    programs.fish.functions = lib.optionalAttrs (toolShell != null) {
      wsh = {
        description = "Open the work tooling's shell (${toolShell}) in ${flatRepos.dir}";
        # Interactive, not login: a login zsh runs macOS path_helper, which
        # reorders PATH before the tooling's own rc runs.
        body = ''
          pushd ${lib.escapeShellArg flatRepos.dir}; or return
          command ${toolShell} -i $argv
          set -l rc $status
          popd
          return $rc
        '';
      };
    };
  })
]
