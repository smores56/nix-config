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

  services.udev.extraRules = lib.mkIf cfg.fingerprint ''
    ATTRS{idVendor}=="27c6", DRIVERS=="cdc_acm", ACTION=="add", RUN+="${pkgs.bash}/bin/bash -c 'echo $kernel > /sys/bus/usb/drivers/cdc_acm/unbind'"
  '';

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
