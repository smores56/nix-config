{
  config,
  lib,
  ...
}:
let
  cfg = config.user;
  inherit (cfg.work) flatRepos;
  hasFlat = config.machine.workHost && flatRepos != null;
in
lib.mkIf hasFlat {
  # Employer tooling and repo discovery share this flat checkout root.
  home.sessionVariables = lib.optionalAttrs (flatRepos.envVar != null) {
    ${flatRepos.envVar} = flatRepos.dir;
  };
}
