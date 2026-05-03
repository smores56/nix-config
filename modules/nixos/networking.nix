{ config, lib, ... }:
{
  networking.networkmanager.enable = true;

  services.openssh = lib.mkIf config.dotfiles.exposeSsh {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };

  services.tailscale = {
    enable = true;
    openFirewall = true;
    useRoutingFeatures = "client";
    extraSetFlags = lib.optionals config.dotfiles.exposeSsh [ "--ssh" ];
  };

  networking.firewall.trustedInterfaces = [ "tailscale0" ];
}
