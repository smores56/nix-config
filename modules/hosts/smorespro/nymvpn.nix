{
  pkgs,
  ...
}:
let
  nym = pkgs.nym-vpn-core;

  # Nym only deletes its resolvconf record on a graceful disconnect. A crash,
  # SIGKILL, or daemon restart otherwise leaves DNS pointing at a dead tunnel IP.
  dnsCleanup = pkgs.writeShellApplication {
    name = "nym-dns-cleanup";
    runtimeInputs = [
      pkgs.openresolv
      pkgs.coreutils
    ];
    text = ''
      shopt -s nullglob
      for dir in /run/resolvconf/keys /run/resolvconf/interface; do
        for record in "$dir"/*.nym; do
          resolvconf -d "$(basename "$record")" -f || true
        done
      done
    '';
  };
in
{
  boot.kernelModules = [ "tun" ];

  environment.systemPackages = [ nym ];

  # Tunnel changes run as root via sudo (one YubiKey touch). No nym-vpn group
  # and no polkit policy: a same-UID process cannot authorize a change.

  systemd.services.nym-vpnd = {
    description = "NymVPN daemon";
    wantedBy = [ "multi-user.target" ];
    after = [
      "NetworkManager.service"
      "network-online.target"
    ];
    wants = [ "network-online.target" ];
    # Keep retrying across a flaky laptop network; the default burst limit would
    # leave the unit failed for the rest of the session.
    startLimitIntervalSec = 0;

    # The daemon shells out during tunnel setup; without these it can fail with
    # Error(TunDevice) even when /dev/net/tun exists.
    path = with pkgs; [
      iproute2
      iptables
      nftables
      openresolv
      coreutils
    ];

    serviceConfig = {
      ExecStart = "${nym}/bin/nym-vpnd run-as-service";
      ExecStartPre = "${dnsCleanup}/bin/nym-dns-cleanup";
      ExecStopPost = "${dnsCleanup}/bin/nym-dns-cleanup";
      Restart = "always";
      RestartSec = 2;

      UMask = "0077";
      StateDirectory = "nym-vpnd";
      StateDirectoryMode = "0700";
      LogsDirectory = "nym-vpnd";
      LogsDirectoryMode = "0700";

      # Host DNS is NetworkManager with rc-manager=resolvconf. Keep config under
      # the state directory instead of the daemon's /etc/nym default.
      Environment = [
        "NYM_DNS_MODULE=resolvconf"
        "NYM_VPND_CONFIG_DIR=%S/nym-vpnd/config"
      ];

      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      # The daemon writes the tunnel DNS and global rp_filter sysctls.
      ProtectKernelTunables = false;
      ProtectControlGroups = false;
      ReadWritePaths = [
        "/etc/resolv.conf"
        "/run/resolvconf"
        "/var/lib/nym-vpnd"
        "/var/log/nym-vpnd"
      ];
    };
  };
}
