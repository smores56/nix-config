{
  # Every NymVPN operation needs root (one YubiKey touch); keep the commands
  # discoverable so the tunnel is not left in a half-configured state.
  user.shellAbbrs = {
    nv = "sudo nym-vpnc";
    nvon = "sudo nym-vpnc connect --wait";
    nvoff = "sudo nym-vpnc disconnect";
    nvst = "sudo nym-vpnc status";
    nvdns = "sudo nym-vpnc dns get";
    nvlan = "sudo nym-vpnc lan set allow";
    nvmix = "sudo nym-vpnc tunnel set --two-hop off";
    nvfast = "sudo nym-vpnc tunnel set --two-hop on";
    nvlog = "sudo tail -f /var/log/nym-vpnd/nym-vpnd.log";
    nvsvc = "systemctl status nym-vpnd";
    nvre = "sudo systemctl restart nym-vpnd";
  };
}
