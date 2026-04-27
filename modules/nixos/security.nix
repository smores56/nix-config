{
  config,
  lib,
  ...
}:
let
  cfg = config.dotfiles;
in
{
  services.fprintd.enable = lib.mkIf cfg.fingerprint true;

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
