{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles;
  flat = cfg.work.flatRepos;
  links = import ../lib/work-repo-links.nix { inherit pkgs; };
in
lib.mkIf (cfg.workHost && flat != null) {
  # Employer tooling sees one flat folder while every checkout stays
  # reachable at <codeRoot>/github.com/<owner>/<repo>.
  home.activation.workRepoLinks = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${lib.getExe links} ${
      lib.escapeShellArgs (
        [
          flat.dir
          "${cfg.codeRoot}/github.com"
        ]
        ++ flat.orgs
      )
    }
  '';

  home.sessionVariables = lib.optionalAttrs (flat.envVar != null) {
    ${flat.envVar} = flat.dir;
  };
}
