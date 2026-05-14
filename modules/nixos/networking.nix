{
  config,
  lib,
  pkgs,
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
  };

  systemd.services.tailscale-ssh = lib.mkIf cfg.exposeSsh {
    after = [ "tailscaled.service" ];
    wants = [ "tailscaled.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [
      config.services.tailscale.package
      pkgs.jq
    ];
    unitConfig.StartLimitIntervalSec = 0;
    serviceConfig = {
      Type = "oneshot";
      Restart = "on-failure";
      RestartSec = "30s";
    };
    script = ''
      state="$(tailscale status --json --peers=false | jq -r '.BackendState')"

      if [ "$state" != "Running" ]; then
        echo "Tailscale backend is $state; retrying Tailscale SSH enablement"
        exit 1
      fi

      tailscale set --ssh
    '';
  };

  networking.firewall.trustedInterfaces = [ "tailscale0" ];
}
