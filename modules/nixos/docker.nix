{
  config,
  lib,
  ...
}:
let
  cfg = config.dotfiles;
in
{
  # Hermes' sandbox uses the Docker terminal backend: the container is the
  # security boundary, so the daemon must run on any host that enables Hermes.
  config = lib.mkIf cfg.hermes.enable {
    virtualisation.docker = {
      enable = true;
      autoPrune = {
        enable = true;
        dates = "weekly";
      };
    };

    users.users.${cfg.username}.extraGroups = [ "docker" ];
  };
}
