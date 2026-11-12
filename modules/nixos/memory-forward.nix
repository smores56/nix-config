# The memory wrapper lives in the k8s guest, but its clients are host-loopback
# conventions: maki's shim, the `memory` CLI and the agent VM's broker all dial
# 127.0.0.1:8182. This unit is that hop, and nothing else — loopback in, the
# guest's NodePort for the wrapper out. No state, no credentials, no data path.
#
# The port is deliberately *not* part of the tunnel rules in `web-proxy.nix`: it is a
# private host-to-guest path, never published to Cloudflare. The wrapper still
# authenticates every request with the bearer token, and the platform's
# NetworkPolicy admits only the tap addresses.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.memoryForward;
  ports = import ../ports.nix;
  facts = import ../lib/vm-host.nix {
    name = "cluster";
    index = 1;
  };
in
{
  options.memoryForward.enable = lib.mkEnableOption ''
    forwarding 127.0.0.1:8182 to the cluster's memory wrapper NodePort. Enable it
    in the same change that stops the host's `memory-mcp` unit, never before: both
    would bind the same loopback port
  '';

  config = lib.mkIf cfg.enable {
    systemd.services.memory-forward = {
      description = "Forward host loopback memory MCP to the cluster wrapper";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      unitConfig = {
        StartLimitIntervalSec = "1h";
        StartLimitBurst = 10;
      };
      serviceConfig = {
        ExecStart = lib.escapeShellArgs [
          "${pkgs.socat}/bin/socat"
          "TCP-LISTEN:${toString ports.memoryMcp},fork,reuseaddr,bind=127.0.0.1"
          "TCP:${facts.guestAddr}:${toString ports.memoryNodePort}"
        ];
        DynamicUser = true;
        Restart = "always";
        RestartSec = "5s";
        MemoryMax = "64M";
        PrivateDevices = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
        ];
        # Only the guest may be dialed; the listener is loopback-only.
        IPAddressAllow = "127.0.0.1 ${facts.guestAddr}";
        IPAddressDeny = "any";
      };
      # A forward that dies silently takes this agent's memory tools with it.
      onFailure = [ "cloudflare-email@%n.service" ];
    };
  };
}
