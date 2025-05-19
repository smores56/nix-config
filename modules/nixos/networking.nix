{ ... }:
{
  # Use Connman for wifi management
  services.connman = {
    enable = true;
    wifi.backend = "iwd";
  };

  # Enable Gnome keyring for secret storage
  services.gnome.gnome-keyring.enable = true;

  # Enable tailscale
  services.tailscale.enable = true;
}
