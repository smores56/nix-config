{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles;
  inherit (cfg.work) flatRepos githubOwnerGlob;
  hasFlat = cfg.workHost && flatRepos != null;
  orgPaths = map (org: "${cfg.codeRoot}/github.com/${org}") flatRepos.orgs;

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
    glob: lib.replaceStrings [ "\\*" "\\?" ] [ ".*" "." ] (lib.escapeRegex (lib.toLower glob));
  outsideGlob = lib.filter (
    org: builtins.match (globRegex githubOwnerGlob) (lib.toLower org) == null
  ) flatRepos.orgs;
in
lib.mkIf hasFlat {
  assertions = [
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

  # Also for processes not started from the tooling's ~/.zshrc.
  home.sessionVariables = lib.optionalAttrs (flatRepos.envVar != null) {
    ${flatRepos.envVar} = flatRepos.dir;
  };
}
