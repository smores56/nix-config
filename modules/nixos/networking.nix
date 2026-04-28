{ config, lib, ... }:
{
  networking.networkmanager.enable = true;

  services.tailscale = {
    enable = true;
    extraSetFlags = lib.optionals config.dotfiles.exposeSsh [ "--ssh" ];
  };

  networking.firewall = {
    trustedInterfaces = [ "tailscale0" ];
    allowedUDPPorts = [ config.services.tailscale.port ];
  };
}
