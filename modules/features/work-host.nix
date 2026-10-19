{
  config,
  lib,
  ...
}:
let
  cfg = config.dotfiles;
  inherit (cfg.work) flatRepos;
  hasFlat = cfg.workHost && flatRepos != null;
in
lib.mkIf hasFlat {
  assertions = [
    {
      # Org links live under codeRoot/github.com; dir inside that would loop.
      assertion = !(lib.hasPrefix "${cfg.codeRoot}/github.com/" "${flatRepos.dir}/");
      message = "dotfiles.work.flatRepos.dir must not be inside ${cfg.codeRoot}/github.com: ${flatRepos.dir}";
    }
  ];

  # Employer tooling sees one flat folder while every checkout stays reachable
  # at <codeRoot>/github.com/<owner>/<repo>. `repos get` links an owner there on
  # first clone; an org dir that already exists as a real directory must be
  # moved into the flat folder manually once.
  home.sessionVariables = lib.optionalAttrs (flatRepos.envVar != null) {
    ${flatRepos.envVar} = flatRepos.dir;
  };
}
