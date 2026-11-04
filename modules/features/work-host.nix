{
  config,
  lib,
  ...
}:
let
  cfg = config.user;
  inherit (cfg.work) flatRepos;
in
lib.mkIf config.machine.workHost {
  # Employer tooling and repo discovery share this flat checkout root.
  home.sessionVariables.${flatRepos.envVar} = flatRepos.dir;
}
