# The `cluster` guest (smores56/sdlc#577): a qemu microVM that runs single-node k3s, borrowed
# by the home-infra agent. App data never enters the guest image: each tree under
# `/var/lib/data` is a virtiofs share mounted into the guest, so host restic keeps backing it
# up unchanged. This module is host-local (smortress only) and owns both sides: the guest
# NixOS config and the tap, firewall and staging units on the host.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  facts = import ../lib/vm-host.nix {
    name = "cluster";
    index = 1;
  };
  ports = import ../ports.nix;
  # Read only to assert the tap, address and state paths never collide with the agent guest.
  agentFacts = import ../lib/agent-vm.nix { inherit pkgs lib; };
  ingest = import ../lib/ingest-vm.nix { inherit lib; };

  user = config.machine.username;

  # All application data stays rw: the pods write the same trees the host apps did. T6 moves
  # each app here; a read-only share would break it before the migration starts.
  dataShares = [
    "immich"
    "music"
    "books"
    "graphiti"
  ];

  # The platform CronJob publishes cluster health and nanobot activity here (#595); the
  # host ingest writer encrypts each new document into Kanbei's inbox. It is *not* a
  # human-owned data share: the tree belongs to the dedicated digest uid at 0770, so a
  # compromised cluster workload cannot inject into a tree Kanbei reads, and `smores` can
  # neither read nor write it. It also sits under the root-only ingest state root, not
  # `/var/lib/data`: that directory is `0751 smores:users`, so its owner could rename or
  # replace the child tree whatever the child's mode. The guest reaches it through an
  # explicit uid mapping.
  digestName = "cluster-digest";
  digestDir = ingest.constants.digestDir;
  digestParent = ingest.constants.digestParent;
  digestTranslation = [
    "--translate-uid=guest:0:${toString ingest.constants.digestUid}:1"
    "--translate-uid=guest:1000:${toString ingest.constants.digestUid}:1"
    "--translate-gid=guest:0:${toString ingest.constants.digestUid}:1"
    "--translate-gid=guest:1000:${toString ingest.constants.digestUid}:1"
    "--modcaps=-mknod"
  ];
  # Every share the k3s guest mounts under /mnt/data.
  mountShares = dataShares ++ [ digestName ];

  # Explicit translation, never the agent VM's squash-to-`smores`: guest root writes as the
  # host's `nobody`, so a compromised workload cannot plant host-root-owned files across the
  # mount, while an app at uid 1000/gid 100 (or 1000) writes as `smores:users`, the ownership
  # host restic and the existing trees already use. Unmapped ids pass through.
  dataTranslation = [
    "--translate-uid=guest:0:65534:1"
    "--translate-uid=guest:1000:1000:1"
    "--translate-gid=guest:0:100:1"
    "--translate-gid=guest:1000:100:1"
    "--modcaps=-mknod"
  ];
  # The token share is read-only and root-owned on the host; mapping guest root to `nobody`
  # keeps host root out of the guest's id space entirely.
  secretTranslation = [
    "--translate-uid=guest:0:65534:1"
    "--translate-gid=guest:0:65534:1"
    "--modcaps=-mknod"
  ];
  # The guest writes the admin kubeconfig through this share; host root reads it.
  kubeconfigTranslation = [
    "--translate-uid=guest:0:65534:1"
    "--translate-gid=guest:0:65534:1"
    "--modcaps=-mknod"
  ];

  privateNets = [
    "0.0.0.0/8"
    "10.0.0.0/8"
    "100.64.0.0/10"
    "127.0.0.0/8"
    "169.254.0.0/16"
    "172.16.0.0/12"
    "192.168.0.0/16"
    "224.0.0.0/3"
  ];

  # The tenant reaches the public internet directly (#625): image pulls, Flux, the
  # cloudflared tunnel edge on TCP/UDP 7844 (without it the ingress connector retries
  # forever instead of ever becoming Ready), package managers and any destination an
  # agent names. This is cluster safety, not DLP: the `privateNets` denies stay because
  # RFC1918, CGNAT, loopback, link-local (the metadata endpoint), multicast and the
  # reserved tail are not "the internet", and the k3s API, the data services and this
  # host's LAN neighbours are not part of the tenant's egress. There is no proxy, no
  # rate cap and no log; the tenant NetworkPolicy carries the same set and has to change
  # in the same revision (smores56/homelabs-platform).
  egressFlows = [
    "-A cluster-vm-fwd -i ${facts.tap} -p tcp -j ACCEPT"
    "-A cluster-vm-fwd -i ${facts.tap} -p udp -j ACCEPT"
  ];

  # Dedicated chains jumped to from the top of INPUT/FORWARD, ahead of nixos-fw and netavark.
  # iptables --not nftables-- because this host's firewall is iptables (`nftables.enable` is
  # off and the agent guest already owns iptables chains); one mechanism filters every tap.
  # `iptables-restore --noflush` replaces each chain atomically and the jumps are never
  # removed, so a firewall restart still filters the tap.
  rules4Lines = [
    "*filter"
    ":cluster-vm-in - [0:0]"
    ":cluster-vm-fwd - [0:0]"
    # Nothing on the host listens for the cluster except replies: k3s is driven from the host.
    "-A cluster-vm-in -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
    "-A cluster-vm-in -j DROP"
    # Replies to host-initiated kubectl/API traffic.
    "-A cluster-vm-fwd -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
    # Default deny between VM taps: the `vm-+` wildcard covers every present and future tap,
    # including a later Kanbei relay tap, which therefore has no forwarding rule by construction.
    "-A cluster-vm-fwd -i ${facts.tap} -o vm-+ -j DROP"
    "-A cluster-vm-fwd -o ${facts.tap} -i vm-+ -j DROP"
  ]
  ++ map (net: "-A cluster-vm-fwd -i ${facts.tap} -d ${net} -j DROP") privateNets
  ++ egressFlows
  # The chain is only entered for this tap in either direction, so an unconditional final drop
  # is the default-deny: nothing new reaches the guest and nothing reaches the host from it.
  ++ [
    "-A cluster-vm-fwd -j DROP"
    "COMMIT"
  ];
  rules4Text = lib.concatStringsSep "\n" rules4Lines + "\n";
  rules4 = pkgs.writeText "cluster-vm-rules4" rules4Text;
  rules6Lines = [
    "*filter"
    ":cluster-vm-in - [0:0]"
    ":cluster-vm-fwd - [0:0]"
    "-A cluster-vm-in -j DROP"
    "-A cluster-vm-fwd -j DROP"
    "COMMIT"
  ];
  rules6Text = lib.concatStringsSep "\n" rules6Lines + "\n";
  rules6 = pkgs.writeText "cluster-vm-rules6" rules6Text;
  firewallUp = ''
    iptables-restore -w --noflush ${rules4}
    ip6tables-restore -w --noflush ${rules6}
    for t in iptables ip6tables; do
      $t -w -C INPUT -i ${facts.tap} -j cluster-vm-in 2>/dev/null || $t -w -I INPUT 1 -i ${facts.tap} -j cluster-vm-in
      $t -w -C FORWARD -i ${facts.tap} -j cluster-vm-fwd 2>/dev/null || $t -w -I FORWARD 1 -i ${facts.tap} -j cluster-vm-fwd
      $t -w -C FORWARD -o ${facts.tap} -j cluster-vm-fwd 2>/dev/null || $t -w -I FORWARD 1 -o ${facts.tap} -j cluster-vm-fwd
    done
  '';

  # Every rule the module writes: asserted to name no Kanbei tap, so a future edit that adds
  # an explicit exception fails evaluation instead of opening a path.
  ruleText = lib.concatStringsSep "\n" [
    rules4Text
    rules6Text
    firewallUp
  ];

  # Host-side staging: directories the virtiofs daemons require, and the k3s token contract.
  # The sops key is not in `secrets/smortress.yaml` yet (it cannot be encrypted here), so the
  # sops file wins when present and a host-local random token is generated otherwise.
  prepScript = pkgs.writeShellScript "cluster-vm-prep" ''
    set -euo pipefail
    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.openssl
      ]
    }
    install -d -m 0700 ${facts.stateDir}
    install -d -m 0700 -o 65534 -g 65534 ${facts.stateDir}/secrets
    install -d -m 0700 -o 65534 -g 65534 ${facts.stateDir}/kubeconfig
    # The digest share's parents are root-only and must exist before virtiofsd starts;
    # `install -d` leaves an existing directory's mode alone, so the tmpfiles rules below
    # stay the authority on 0700.
    install -d -m 0700 -o root -g root ${ingest.constants.stateRoot}
    install -d -m 0700 -o root -g root ${digestParent}
    install -d -m 0770 -o ${toString ingest.constants.digestUid} -g ${toString ingest.constants.digestUid} ${digestDir}
    if [ -s /run/secrets/k3s-cluster-token ]; then
      install -m 0400 -o 65534 -g 65534 /run/secrets/k3s-cluster-token ${facts.stateDir}/secrets/k3s-cluster-token
    elif [ ! -s ${facts.stateDir}/secrets/k3s-cluster-token ]; then
      umask 077
      openssl rand -hex 32 > ${facts.stateDir}/secrets/k3s-cluster-token
      chown 65534:65534 ${facts.stateDir}/secrets/k3s-cluster-token
      chmod 0400 ${facts.stateDir}/secrets/k3s-cluster-token
    fi
  '';

  netScript = pkgs.writeShellScript "cluster-vm-net" ''
    set -eu
    ${pkgs.procps}/bin/sysctl -qw net.ipv6.conf.${facts.tap}.disable_ipv6=1
    ${pkgs.iproute2}/bin/ip addr replace ${facts.hostAddr}/30 dev ${facts.tap}
    ${pkgs.iproute2}/bin/ip link set ${facts.tap} up
  '';

  clusterKubectl = pkgs.writeShellScriptBin "cluster-kubectl" ''
    exec ${pkgs.kubectl}/bin/kubectl --kubeconfig ${facts.stateDir}/kubeconfig/admin.conf "$@"
  '';

  guest =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      # sops-nix is not imported in the guest today, so the contract path is the default.
      # When it does import sops-nix and `k3s-cluster-token` is registered, use its path.
      hasSopsToken = config ? sops && config.sops.secrets ? k3s-cluster-token;
      tokenFile = lib.mkDefault (
        if hasSopsToken then
          config.sops.secrets.k3s-cluster-token.path
        else
          "/run/secrets/k3s-cluster-token"
      );
    in
    {
      microvm = {
        hypervisor = "qemu";
        vcpu = 8;
        # Measured working set is ~5 GiB (3.7 GiB pods + ~0.5 GiB k3s/kernel); the rest of the
        # old 15 GiB was guest page cache the guest reclaims on demand.
        mem = 10240;
        # The guest reads /nix/store through the share; registering the closure would let a
        # guest `nix store gc` unlink host paths it never owned.
        registerClosure = false;
        interfaces = [
          {
            type = "tap";
            id = facts.tap;
            inherit (facts) mac;
          }
        ];
        shares = [
          {
            tag = "ro-store";
            source = "/nix/store";
            mountPoint = "/nix/store";
            proto = "virtiofs";
            readOnly = true;
          }
        ]
        ++ map (name: {
          tag = "data-${name}";
          source = "/var/lib/data/${name}";
          mountPoint = "/mnt/data/${name}";
          proto = "virtiofs";
          posixAcl = false;
          extraArgs = dataTranslation;
        }) dataShares
        ++ [
          {
            tag = "data-${digestName}";
            source = digestDir;
            mountPoint = "/mnt/data/${digestName}";
            proto = "virtiofs";
            posixAcl = false;
            extraArgs = digestTranslation;
          }
        ]
        ++ [
          {
            tag = "k3s-token";
            source = "${facts.stateDir}/secrets";
            mountPoint = "/run/secrets";
            proto = "virtiofs";
            readOnly = true;
            posixAcl = false;
            extraArgs = secretTranslation;
          }
          {
            tag = "kubeconfig";
            source = "${facts.stateDir}/kubeconfig";
            mountPoint = "/run/cluster-vm/kubeconfig";
            proto = "virtiofs";
            posixAcl = false;
            extraArgs = kubeconfigTranslation;
          }
        ];
        # k3s state and container images live here; no writable nix store because the guest
        # never builds.
        volumes = [
          {
            image = "var.img";
            mountPoint = "/var";
            size = 65536;
          }
        ];
      };

      networking = {
        hostName = facts.name;
        useNetworkd = true;
        nameservers = [
          "1.1.1.1"
          "9.9.9.9"
        ];
        # One tap NIC: the API and kubelet are the only listeners the host needs to reach.
        firewall.allowedTCPPorts = [
          6443
          10250
          # The memory wrapper's NodePort; the platform's Service manifest must name the
          # same literal, and its NetworkPolicy admits only the tap addresses.
          ports.memoryNodePort
        ];
      };
      systemd.network.networks."10-tap" = {
        matchConfig.MACAddress = facts.mac;
        address = [ "${facts.guestAddr}/30" ];
        routes = [ { Gateway = facts.hostAddr; } ];
        networkConfig.IPv6AcceptRA = false;
        linkConfig.RequiredForOnline = "routable";
      };
      boot.kernel.sysctl."net.ipv6.conf.all.disable_ipv6" = 1;

      services.k3s = {
        enable = true;
        role = "server";
        inherit tokenFile;
        # Flux owns every addon that can be reinstalled declaratively. CoreDNS and the
        # local-storage addon stay: Flux's own Git sources resolve service names, and the
        # platform's `local-path` StorageClass is k3s's built-in provisioner (the manifests
        # reference it, so disabling the addon would strand every PVC).
        disable = [
          "traefik"
          "servicelb"
          "metrics-server"
        ];
        # gVisor: the shim (containerd-shim-runsc-v1) must be on the service PATH. The v2
        # template is the one the NixOS module writes and containerd 2 still renders it; the
        # `gvisor` RuntimeClass (handler `runsc`) is a platform-repo object (smores56/sdlc#578).
        containerdConfigTemplate = ''
          {{ template "base" . }}

          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]
            runtime_type = "io.containerd.runsc.v1"
          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc.options]
            TypeUrl = "io.containerd.runsc.v1.options"
        '';
      };
      systemd.services.k3s = {
        path = [ pkgs.gvisor ];
        # The token and the hostPath PV trees must be mounted before the API and kubelet start.
        unitConfig.RequiresMountsFor = [ "/run/secrets" ] ++ map (name: "/mnt/data/${name}") mountShares;
      };

      # The host drives the API as root, but /etc/rancher/k3s/k3s.yaml points at loopback.
      # Publish a copy on the rw share with the tap address, owned by nobody on the host.
      systemd.services.cluster-kubeconfig = {
        description = "Publish a host-readable kubeconfig for the cluster API";
        wantedBy = [ "multi-user.target" ];
        after = [ "k3s.service" ];
        wants = [ "k3s.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          set -eu
          out=/run/cluster-vm/kubeconfig
          ${pkgs.coreutils}/bin/install -d -m 0700 "$out"
          if [ ! -s /etc/rancher/k3s/k3s.yaml ]; then
            for _ in $(${pkgs.coreutils}/bin/seq 1 120); do
              if [ -s /etc/rancher/k3s/k3s.yaml ]; then break; fi
              ${pkgs.coreutils}/bin/sleep 1
            done
          fi
          ${pkgs.gnused}/bin/sed \
            's#https://127.0.0.1:6443#https://${facts.guestAddr}:6443#' \
            /etc/rancher/k3s/k3s.yaml > "$out/.admin.conf"
          ${pkgs.coreutils}/bin/chmod 0600 "$out/.admin.conf"
          ${pkgs.coreutils}/bin/mv "$out/.admin.conf" "$out/admin.conf"
        '';
      };

      systemd.tmpfiles.rules = [
        "d /run/cluster-vm 0755 root root -"
      ];

      system.stateVersion = "26.05";
    };
in
{
  imports = [ inputs.microvm.nixosModules.host ];

  microvm.vms.${facts.name} = {
    autostart = true;
    # A host switch must not bounce the cluster; `systemctl restart microvm@cluster` is explicit.
    restartIfChanged = false;
    config = guest;
  };

  # The shares' host paths must exist before virtiofsd starts. immich/graphiti are empty until
  # T6 moves the apps; music and books already exist from the host's own tmpfiles. The digest
  # tree is the one share the human does not own: it sits in a 0700 root parent chain (never
  # `/var/lib/data`, which `smores` owns at 0751 and could therefore rename) and is 0770 on a
  # dedicated uid, so the human account can neither replace nor read it.
  systemd.tmpfiles.rules = map (name: "d /var/lib/data/${name} 0775 ${user} users -") dataShares ++ [
    "d ${ingest.constants.stateRoot} 0700 root root -"
    "d ${digestParent} 0700 root root -"
    "d ${digestDir} 0770 ${ingest.constants.digestUser} ${ingest.constants.digestUser} -"
  ];

  users.groups.${ingest.constants.digestUser}.gid = ingest.constants.digestUid;
  users.users.${ingest.constants.digestUser} = {
    isSystemUser = true;
    uid = ingest.constants.digestUid;
    group = ingest.constants.digestUser;
    description = "cluster digest writer (the cluster guest's one-way feed to Kanbei)";
  };

  systemd.services = {
    cluster-vm-prep = {
      description = "Stage the cluster VM's state, data shares and k3s token";
      before = [
        "microvm-tap-interfaces@${facts.name}.service"
        "microvm-virtiofsd@${facts.name}.service"
        "microvm@${facts.name}.service"
      ];
      requiredBy = [ "microvm-virtiofsd@${facts.name}.service" ];
      partOf = [ "microvm@${facts.name}.service" ];
      # The VM requires this unit, so a host-switch restart would drop the cluster.
      restartIfChanged = false;
      after = [ "local-fs.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = prepScript;
        # Future vsock relays (kanbei) keep their sockets here root-only; the cluster guest
        # uses no vsock today, but the directory is part of the host contract.
        RuntimeDirectory = "cluster-vm";
        RuntimeDirectoryMode = "0700";
      };
    };

    # Firecracker's notify.vsock is unused by this guest today; the umask keeps any future
    # socket in the state directory owner-only.
    "microvm@${facts.name}" = {
      overrideStrategy = "asDropin";
      serviceConfig.UMask = "0077";
    };

    cluster-vm-net = {
      description = "Address the cluster VM's tap";
      after = [ "microvm-tap-interfaces@${facts.name}.service" ];
      bindsTo = [ "microvm-tap-interfaces@${facts.name}.service" ];
      before = [ "microvm@${facts.name}.service" ];
      requiredBy = [ "microvm@${facts.name}.service" ];
      restartIfChanged = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = netScript;
      };
    };
  };

  networking = {
    nat = {
      enable = true;
      internalInterfaces = [ facts.tap ];
    };
    networkmanager.unmanaged = [ facts.tap ];
    firewall.extraCommands = firewallUp;
  };

  environment.systemPackages = [ clusterKubectl ];

  assertions = [
    {
      assertion = config.networking.firewall.enable && !config.networking.nftables.enable;
      message = "cluster-vm: the tap is filtered with iptables extraCommands; this host must not enable nftables";
    }
    {
      assertion = !(lib.hasInfix "kanbei" ruleText);
      message = "cluster-vm: no firewall rule may name a Kanbei tap; the relay is host-only and the cluster has no route to it";
    }
    {
      assertion =
        facts.tap != agentFacts.tap
        && facts.stateDir != agentFacts.stateDir
        && facts.vmStateDir != agentFacts.vmStateDir;
      message = "cluster-vm: the cluster guest must not share a tap or a state path with the agent guest";
    }
    {
      # The digest writer (#595) reads this share through the ingest module; a rename here
      # would silently stop the one-way cluster feed, and dropping back to a human-owned
      # data share would let maki inject content into Kanbei's inbox.
      assertion =
        let
          guest = config.microvm.vms.${facts.name}.config.config;
          share = lib.findFirst (s: s.tag == "data-${digestName}") null guest.microvm.shares;
        in
        !(builtins.elem digestName dataShares)
        && share != null
        && share.source == digestDir
        && share.mountPoint == "/mnt/data/${digestName}"
        && !(share.readOnly or false)
        && lib.any (a: lib.hasInfix "guest:1000:${toString ingest.constants.digestUid}:1" a) share.extraArgs
        && lib.elem "d ${digestParent} 0700 root root -" config.systemd.tmpfiles.rules
        && lib.elem "d ${digestDir} 0770 ${ingest.constants.digestUser} ${ingest.constants.digestUser} -" config.systemd.tmpfiles.rules
        && !lib.hasPrefix "/var/lib/data/" digestDir
        && lib.hasPrefix "${ingest.constants.stateRoot}/" digestDir
        && ingest.constants.digestUid != config.users.users.${user}.uid;
      message = "cluster-vm: the cluster-digest tree must be 0770 on the dedicated digest uid under a root-only parent (never /var/lib/data, which ${user} owns), mapped explicitly for the guest, and never owned by ${user}";
    }
    {
      # #635: nanobot mounts the books tree and writes it directly as uid 1000; the share
      # maps that onto the host's `smores:users`, the ownership the library and restic
      # already use. A translation change would silently make the pods write as nobody.
      assertion =
        let
          guest = config.microvm.vms.${facts.name}.config.config;
          share = lib.findFirst (s: s.tag == "data-books") null guest.microvm.shares;
        in
        lib.elem "books" dataShares
        && share != null
        && share.source == "/var/lib/data/books"
        && share.mountPoint == "/mnt/data/books"
        && !(share.readOnly or false)
        && lib.elem "--translate-uid=guest:1000:${toString config.users.users.${user}.uid}:1" share.extraArgs
        && lib.elem "--translate-gid=guest:1000:${toString config.users.groups.users.gid}:1" share.extraArgs;
      message = "cluster-vm: the books share must map guest 1000 onto ${user}:users, because nanobot writes the library as uid 1000";
    }
    {
      assertion =
        config.systemd.services."cluster-vm-prep".restartIfChanged == false
        && config.systemd.services."cluster-vm-net".restartIfChanged == false
        && config.microvm.vms.${facts.name}.restartIfChanged == false;
      message = "cluster-vm: prep/net and the VM must not restart on a host switch";
    }
  ];
}
