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

  links = import ../lib/work-repo-links.nix { inherit pkgs; };
  # The owner glob, not a list of owner names: the set of linked orgs is
  # whatever matches it, so no employer org name lives in the repo.
  linkArgs = lib.escapeShellArgs [
    flatRepos.dir
    "${cfg.codeRoot}/github.com"
    githubOwnerGlob
  ];
  # This host's layout baked in, so `work-repo-links --migrate` needs no args.
  hostLinks = pkgs.writeShellScriptBin "work-repo-links" ''
    case "''${1-}" in
      "") exec ${lib.getExe links} ${linkArgs} ;;
      --migrate) exec ${lib.getExe links} --migrate ${linkArgs} ;;
      *) printf 'usage: work-repo-links [--migrate]\n' >&2; exit 2 ;;
    esac
  '';
in
lib.mkIf hasFlat {
  assertions = [
    {
      # Org links live under codeRoot/github.com; dir inside that would loop.
      assertion = !(lib.hasPrefix "${cfg.codeRoot}/github.com/" "${flatRepos.dir}/");
      message = "dotfiles.work.flatRepos.dir must not be inside ${cfg.codeRoot}/github.com: ${flatRepos.dir}";
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
