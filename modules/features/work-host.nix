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
  home.sessionVariables.${flatRepos.envVar} = flatRepos.dir;
}
