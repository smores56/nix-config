{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles;
in
{
  services.fprintd = lib.mkIf cfg.fingerprint {
    enable = true;
    tod = {
      enable = true;
      driver = pkgs.libfprint-2-tod1-goodix;
    };
  };

  security.pam.services.noctalia-shell =
    if cfg.fingerprint then
      { fprintAuth = true; }
    else
      {
        text = ''
          auth include login
        '';
      };
}
