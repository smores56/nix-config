# Remote access is Cloudflare-Tunnel-only (modules/nixos/web-proxy.nix): no mesh
# VPN, no open inbound port. NetworkManager owns the physical links.
_:

{
  networking.networkmanager.enable = true;
}
