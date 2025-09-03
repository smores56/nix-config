{
  systemd.services.rfkill-unblock = {
    description = "Automatic unblocking of all wireless connectivity.";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "/run/current-system/sw/bin/rfkill unblock all";
      After = [
        "iwd.service"
        "bluetooth.service"
      ];
      Requires = [
        "iwd.service"
        "bluetooth.service"
      ];
    };
  };
}
