{
  config,
  pkgs,
  ...
}:
let
  nym = pkgs.nym-vpn-core;
  hardening = import ../../lib/hardening.nix;

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

  # A SIGKILLed daemon leaves the nftables kill-switch table behind; it keeps
  # dropping traffic until the next successful start resets it.
  firewallCleanup = pkgs.writeShellApplication {
    name = "nym-firewall-cleanup";
    runtimeInputs = [ pkgs.nftables ];
    text = ''
      nft delete table inet nym 2>/dev/null || true
    '';
  };
in
{
  boot.kernelModules = [ "tun" ];

  environment.systemPackages = [
    nym
    # Operator recovery: nft list tables / nft delete table inet nym.
    pkgs.nftables
  ];

  # Tunnel changes run as root via sudo. Upstream authorizes uid 0, then an
  # optional nym-vpn group, then polkit; we create no group and ship no policy,
  # and ProtectSystem keeps /usr and /etc read-only so the daemon cannot
  # install its polkit fallback. An unprivileged process is refused. A process
  # on this user's TTY can still reuse a live sudo ticket (timestamp_timeout=5).

  # NYM_DNS_MODULE=resolvconf is only valid when openresolv owns /etc/resolv.conf.
  assertions = [
    {
      assertion = config.networking.resolvconf.enable;
      message = "nymvpn.nix: NYM_DNS_MODULE=resolvconf requires networking.resolvconf";
    }
  ];

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

    # The daemon shells out to system tools during setup (resolvconf, ip); the
    # firewall itself is in-process libnftnl. Keep them on PATH so a missing
    # lookup cannot surface as a misleading TunDevice error.
    path = with pkgs; [
      iproute2
      iptables
      nftables
      openresolv
      coreutils
    ];

    serviceConfig = hardening // {
      ExecStart = "${nym}/bin/nym-vpnd run-as-service";
      ExecStartPre = [
        "${dnsCleanup}/bin/nym-dns-cleanup"
        "${firewallCleanup}/bin/nym-firewall-cleanup"
      ];
      ExecStopPost = [
        "${dnsCleanup}/bin/nym-dns-cleanup"
        "${firewallCleanup}/bin/nym-firewall-cleanup"
      ];
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

      # The daemon writes the tunnel DNS and global sysctls.
      ProtectKernelTunables = false;
      ProtectControlGroups = false;
      ReadWritePaths = [
        "/etc/resolv.conf"
        # The daemon creates /var/run/nym-vpn.sock here.
        "/run"
        "/run/resolvconf"
        "/var/lib/nym-vpnd"
        "/var/log/nym-vpnd"
      ];
    };
  };
}
