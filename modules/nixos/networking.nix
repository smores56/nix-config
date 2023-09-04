{ pkgs, ... }: {
  # Use NetworkManager for wifi management
  networking.networkmanager = {
    enable = true;
    wifi.backend = "iwd";
  };

  # Enable tailscale
  environment.systemPackages = [ pkgs.tailscale ];
  services.tailscale.enable = true;
}
