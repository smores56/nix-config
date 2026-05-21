{
  config,
  lib,
  ...
}:
{
  config = {
    system.activationScripts.linger = ''
      $DRY_RUN_CMD ${config.systemd.package}/bin/loginctl enable-linger ${config.dotfiles.username}
    '';
  };
}
