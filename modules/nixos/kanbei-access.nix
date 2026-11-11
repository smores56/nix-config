# Host access path for the kanbei guest (smores56/sdlc#586, part of #509).
#
# Three things live here, all behind `kanbeiVm.enable`:
#
# 1. The chat relay: a TCP-to-vsock pipe under its own UID. systemd's socket unit performs the
#    privileged bind on loopback, hands the descriptor to the unprivileged relay, and only the
#    tunnel's group may connect. The relay never parses TLS; the guest terminates it.
# 2. The ACME responder: the guest sends a fixed-CN CSR over AF_VSOCK and gets a Certbot
#    DNS-01 chain back. The private key never leaves the guest.
# 3. The private hostname: `kanbei.sammohr.dev` resolves to loopback *on this host only*, so
#    cloudflared's hostname route reaches the relay without an ingress rule. No public
#    hostname is declared here; the OpenTofu fragment is in docs/kanbei-access.md.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.kanbeiVm;
  ports = import ../ports.nix;
  access = import ../lib/kanbei-access.nix;
  facts = import ../lib/vm-host.nix {
    name = "kanbei";
    index = 2;
    vsockCid = 4;
  };

  tools = pkgs.runCommandLocal "kanbei-tools" { } ''
    mkdir -p $out
    cp -R ${../lib/kanbei}/. $out/
    # A local test run can leave bytecode in the source tree; it has no place in the image.
    chmod -R u+w $out
    find $out -name __pycache__ -type d -prune -exec rm -rf {} +
  '';

  python = "${pkgs.python3}/bin/python3";
  relayScript = "${tools}/relay.py";
  certHostScript = "${tools}/cert_host.py";

  tunnelUnit = "cloudflared-tunnel-${config.webProxy.tunnelName}";

  relayPort = ports.kanbei;
  # The private hostname route is Layer 4: the client's destination port is preserved, so a
  # browser's https://kanbei.sammohr.dev reaches the loopback listener on 443.
  expectedPort = 443;

  firewallChain = "kanbei-relay-in";
  firewallCommands = ''
    ${pkgs.iptables}/bin/iptables -w -N ${firewallChain} 2>/dev/null || true
    ${pkgs.iptables}/bin/iptables -w -F ${firewallChain}
    ${pkgs.iptables}/bin/iptables -w -A ${firewallChain} -i lo -p tcp --dport ${toString relayPort} \
      -m conntrack --ctstate NEW -j ACCEPT
    ${pkgs.iptables}/bin/iptables -w -A ${firewallChain} -j RETURN
    ${pkgs.iptables}/bin/iptables -w -C INPUT -i lo -p tcp --dport ${toString relayPort} \
      -j ${firewallChain} 2>/dev/null \
      || ${pkgs.iptables}/bin/iptables -w -I INPUT 1 -i lo -p tcp --dport ${toString relayPort} \
        -j ${firewallChain}
  '';

  assertion = cond: message: {
    assertion = cond;
    inherit message;
  };
in
{
  config = lib.mkIf cfg.enable {
    # The relay identity: no shell, no home content, only this unit's group.
    users.groups.${access.tunnelGroup} = { };
    users.users.${access.relayUser} = {
      isSystemUser = true;
      group = access.relayUser;
      home = "/var/lib/${access.relayUser}";
      description = "Kanbei chat relay (TCP to vsock)";
    };
    users.groups.${access.relayUser} = { };
    users.users.kanbei-acme = {
      isSystemUser = true;
      group = "kanbei-acme";
      home = access.acmeStateDir;
      description = "Kanbei ACME responder (DNS-01)";
    };
    users.groups.kanbei-acme = { };

    systemd.tmpfiles.rules = [
      "d /var/lib/${access.relayUser} 0700 ${access.relayUser} ${access.relayUser} -"
      "d ${access.acmeStateDir} 0700 kanbei-acme kanbei-acme -"
    ];

    # The private hostname route makes cloudflared resolve the name on its own host. Loopback
    # is the only answer, so neither a public A/AAAA record nor the wildcard CNAME can point
    # the tunnel anywhere else.
    networking.hosts."127.0.0.1" = [ access.hostname ];

    # cloudflared runs as a DynamicUser, so a named supplementary group is how its uid gets
    # the socket. The socket is loopback-only and 0660; no other local user can connect.
    systemd.services.${tunnelUnit}.serviceConfig.SupplementaryGroups = lib.mkIf (
      config.services.cloudflared.tunnels ? ${config.webProxy.tunnelName}
    ) [ access.tunnelGroup ];

    systemd.sockets.kanbei-chat-relay = {
      description = "Kanbei chat relay listener (loopback, tunnel group only)";
      wantedBy = [ "sockets.target" ];
      socketConfig = {
        ListenStream = "127.0.0.1:${toString relayPort}";
        SocketMode = "0660";
        SocketGroup = access.tunnelGroup;
        Accept = false;
      };
    };

    systemd.services.kanbei-chat-relay = {
      description = "Kanbei chat relay: TCP 127.0.0.1:${toString relayPort} to vsock chat";
      requires = [ "kanbei-chat-relay.socket" ];
      after = [
        "kanbei-chat-relay.socket"
        "microvm@${facts.name}.service"
      ];
      restartIfChanged = false;
      serviceConfig = {
        User = access.relayUser;
        Group = access.relayUser;
        ExecStart = "${python} ${relayScript} --vsock-cid ${toString facts.vsockCid} --vsock-port ${toString access.chatVsockPort}";
        Restart = "always";
        RestartSec = "1s";
        UMask = "0077";
        # The relay needs no device node: AF_VSOCK is a syscall. PrivateDevices keeps the
        # root-only /dev/vhost-vsock (QEMU's) out of its view entirely.
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_VSOCK"
        ];
        SystemCallArchitectures = "native";
        SystemCallFilter = "@system-service";
      };
    };

    # The guest asks; the host signs. Lego is invoked with --csr, so the key stays in the
    # guest and this unit never has private key material to protect.
    systemd.services.kanbei-acme = {
      description = "Kanbei ACME responder (fixed-CN CSR over vsock, DNS-01 via Cloudflare)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      restartIfChanged = false;
      serviceConfig = {
        User = "kanbei-acme";
        Group = "kanbei-acme";
        LoadCredential = [
          "dns-api-token:${config.sops.secrets.cloudflare-api-token.path}"
        ];
        ExecStart = "${python} ${certHostScript} --port ${toString access.certVsockPort} --state-dir ${access.acmeStateDir} --email ${lib.escapeShellArg config.user.email} --lego ${pkgs.lego}/bin/lego --openssl ${pkgs.openssl}/bin/openssl --token-file %d/dns-api-token";
        Restart = "always";
        RestartSec = "5s";
        UMask = "0077";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ReadWritePaths = [ access.acmeStateDir ];
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        LockPersonality = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
          "AF_NETLINK"
          "AF_VSOCK"
        ];
        SystemCallArchitectures = "native";
        SystemCallFilter = "@system-service";
      };
    };

    # Only this one loopback port is opened; the chain is reached only for that dport, so no
    # other local listener gains a rule. Guests never see it: kanbei has no NIC and the
    # cluster/agent firewall chains contain no kanbei rule (asserted in cluster-vm.nix and
    # below).
    networking.firewall.extraCommands = firewallCommands;

    assertions = [
      (assertion (
        relayPort == expectedPort
      ) "kanbei-access: the private hostname route preserves port 443; ports.kanbei must be 443")
      (assertion (lib.hasInfix "127.0.0.1:${toString relayPort}" config.systemd.sockets.kanbei-chat-relay.socketConfig.ListenStream) "kanbei-access: the relay socket must bind loopback only")
      (assertion (
        config.webProxy.tunnelName != ""
      ) "kanbei-access: kanbei needs the host's cloudflared tunnel; webProxy.tunnelName is empty")
      (assertion (
        !(config.webProxy.services ? kanbei)
      ) "kanbei-access: kanbei must not be a webProxy service; that would create a public ingress rule")
      (assertion (
        config.systemd.services.kanbei-chat-relay.restartIfChanged == false
        && config.systemd.services.kanbei-acme.restartIfChanged == false
      ) "kanbei-access: the relay socket/service and ACME responder must not restart on a host switch")
      (assertion (
        config.microvm.vms.${facts.name}.config.config.microvm.interfaces == [ ]
      ) "kanbei-access: the kanbei guest must stay NIC-less; the relay is the only path in")
      (assertion (
        !(lib.hasInfix "-i vm-" firewallCommands) && !(lib.hasInfix "FORWARD" firewallCommands)
      ) "kanbei-access: the relay firewall rule must be loopback input only, never a forwarding rule")
      (assertion (
        config.users.groups ? ${access.tunnelGroup}
      ) "kanbei-access: the tunnel group must exist before cloudflared joins it")
      (assertion (
        (config.networking.hosts ? "127.0.0.1")
        && lib.elem access.hostname config.networking.hosts."127.0.0.1"
      ) "kanbei-access: the host must resolve ${access.hostname} to loopback for cloudflared")
    ];
  };
}
