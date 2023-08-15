{ pkgs, ... }: {
  # Use NetworkManager for wifi management
  networking.networkmanager.enable = true;
  systemd.services.NetworkManager = {
    wantedBy = [ "suspend.target" ];
    partOf = [ "suspend.target" ];
  };

  # Persist NetworkManager on reboot/lock
  systemd.services.NetworkManager-wait-online.enable = true;

  # Enable tailscale
  environment.systemPackages = [ pkgs.tailscale ];
  services.tailscale.enable = true;
}
