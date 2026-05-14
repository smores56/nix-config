{
  config,
  lib,
  ...
}:
let
  cfg = config.dotfiles;
in
{
  networking.networkmanager.enable = true;

  services.tailscale = {
    enable = true;
    openFirewall = true;
    useRoutingFeatures = "client";
    authKeyFile = cfg.tailscaleAuthKeyFile;
    extraUpFlags = lib.optionals cfg.exposeSsh [ "--ssh" ];
    extraSetFlags = lib.optionals cfg.exposeSsh [ "--ssh" ];
  };

  networking.firewall.trustedInterfaces = [ "tailscale0" ];
}
