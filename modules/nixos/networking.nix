{ config, lib, ... }:
{
  networking.networkmanager.enable = true;

  services.tailscale = {
    enable = true;
    openFirewall = true;
    useRoutingFeatures = "client";
    extraSetFlags = lib.optionals config.dotfiles.exposeSsh [ "--ssh" ];
  };

  networking.firewall.trustedInterfaces = [ "tailscale0" ];
}
