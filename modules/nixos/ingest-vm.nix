# The ingest plane (smores56/sdlc#588, part of #509): five Firecracker microVMs, one per source,
# each with a single tap, a read-only secret volume and a vsock channel to a host writer. All
# egress leaves through the host proxy and resolver on the tap's host address; the host writer
# age-encrypts each batch to Kanbei's published recipient and drops it into the read-only inbox
# share. Behind `ingestVm.enable` because the writer needs the Kanbei guest's key.
#
# Facts and policy (allowlists, windows, chains) live in `modules/lib/ingest-vm.nix`; this file
# is the host/guest rendering and the host plumbing.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.ingestVm;
  ingest = import ../lib/ingest-vm.nix { inherit lib; };
  inherit (ingest)
    constants
    sources
    sourceIds
    firewallTable
    firewallUp
    ;

  hardening = import ../lib/hardening.nix;

  # One directory of plain stdlib Python; every service imports `policy` from beside itself.
  ingestTools = pkgs.runCommand "kanbei-ingest-tools" { } ''
    mkdir -p $out/lib/kanbei-ingest
    cp ${../lib/ingest}/*.py $out/lib/kanbei-ingest/
  '';

  mkTool =
    name: script: extraInputs: args:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [
        pkgs.python3
        pkgs.coreutils
        pkgs.age
      ]
      ++ extraInputs;
      text = ''
        exec ${pkgs.python3}/bin/python3 ${ingestTools}/lib/kanbei-ingest/${script}.py ${args} "$@"
      '';
    };

  ingestWriter = mkTool "ingest-writer" "writer" [ ] "";
  ingestAgeKey = mkTool "ingest-age-key" "age_key" [ ] "";
  ingestProxy = mkTool "ingest-proxy" "proxy" [ ] "";
  ingestResolver = mkTool "ingest-resolver" "resolver" [ ] "";
  ingestHeartbeat = mkTool "ingest-heartbeat" "heartbeat" [ ] "";

  kanbeiLogs = pkgs.writeShellApplication {
    name = "kanbei-logs";
    runtimeInputs = [
      pkgs.python3
      pkgs.systemd
      pkgs.coreutils
      pkgs.gnugrep
    ];
    text = ''
      exec ${pkgs.python3}/bin/python3 ${../lib/ingest/kanbei_logs.py} "$@"
    '';
  };

  kanbeiIngestVerify = pkgs.writeShellApplication {
    name = "kanbei-ingest-verify";
    runtimeInputs = [
      pkgs.python3
      pkgs.age
      pkgs.systemd
      pkgs.iptables
      pkgs.iproute2
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.curl
    ];
    text = ''
      exec ${pkgs.python3}/bin/python3 ${../lib/ingest/verify.py} "$@"
    '';
  };

  # Kanbei's vsock port is host-initiated lookups inverted: the guest dials host CID 2, so
  # Firecracker accepts on `<uds>_<port>` beside its own control socket.
  kanbeiUds = "/var/lib/microvms/kanbei/notify.vsock_${toString constants.ageKeyPort}";
  recipientFile = "${constants.stateRoot}/age-recipient";

  # Every tap address and state path is derived once, in the shared table.

  # The guest side: one tap, one secret volume, vsock, and no route other than the host.
  guestFor =
    id:
    let
      s = sources.${id};
      f = ingest.factsFor id;
      emitter = pkgs.writeShellApplication {
        name = "ingest-emit";
        runtimeInputs = [ pkgs.python3 ];
        text = ''
          exec ${pkgs.python3}/bin/python3 ${ingestTools}/lib/kanbei-ingest/guest_emit.py "$@"
        '';
      };
      proxyEnv = {
        HTTP_PROXY = "http://${f.hostAddr}:${toString constants.proxyPort}";
        HTTPS_PROXY = "http://${f.hostAddr}:${toString constants.proxyPort}";
        ALL_PROXY = "http://${f.hostAddr}:${toString constants.proxyPort}";
        http_proxy = "http://${f.hostAddr}:${toString constants.proxyPort}";
        https_proxy = "http://${f.hostAddr}:${toString constants.proxyPort}";
        no_proxy = "localhost,127.0.0.1";
      };
    in
    lib.mkMerge [
      {
        microvm = {
          hypervisor = "firecracker";
          # Mandatory for Firecracker; inside the microvm user's 0775 state dir so it can bind.
          socket = "${f.vmStateDir}/firecracker.sock";
          inherit (s) vcpu mem;
          # The store is a read-only squashfs disk, never a share: Firecracker has no shares.
          registerClosure = false;
          interfaces = [
            {
              type = "tap";
              id = f.tap;
              inherit (f) mac;
            }
          ];
          vsock.cid = s.vsockCid;
          # One read-only block device, built by the host prep unit from /run/secrets/<id>-env.
          # It is the only volume, so the store disk takes vda and this one vdb.
          volumes = [
            {
              image = "/var/lib/microvms/ingest-secrets/${id}.img";
              mountPoint = "/run/ingest-secret";
              fsType = "ext4";
              readOnly = true;
              autoCreate = false;
            }
          ];
        };

        networking = {
          hostName = s.guest;
          useNetworkd = true;
          nameservers = [ f.hostAddr ];
          # The guest firewall is iptables; the host's is too (nftables stays off host-wide).
          nftables.enable = false;
          firewall = {
            enable = true;
            extraCommands = ''
              iptables -w -A OUTPUT -o lo -j ACCEPT
              iptables -w -A OUTPUT -d ${f.hostAddr} -p tcp --dport ${toString constants.proxyPort} -j ACCEPT
              iptables -w -A OUTPUT -d ${f.hostAddr} -p udp --dport ${toString constants.dnsPort} -j ACCEPT
              iptables -w -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
              iptables -w -A OUTPUT -j REJECT
            '';
          };
        };

        systemd.network.networks."10-tap" = {
          matchConfig.MACAddress = f.mac;
          address = [ "${f.guestAddr}/30" ];
          routes = [ { Gateway = f.hostAddr; } ];
          networkConfig = {
            IPv6AcceptRA = false;
            DNS = [ f.hostAddr ];
          };
          linkConfig.RequiredForOnline = "routable";
        };
        boot.kernelModules = [
          "vsock"
          "vmw_vsock_virtio_transport"
        ];
        boot.kernel.sysctl."net.ipv6.conf.all.disable_ipv6" = 1;
        services.timesyncd.enable = false;
        environment.variables = proxyEnv;

        systemd.tmpfiles.rules = [
          "d /var/lib/ingest 0700 root root -"
          "d /var/lib/ingest/outbox 0700 root root -"
          "d /var/lib/ingest/sent 0700 root root -"
          "d /var/lib/ingest/rejected 0700 root root -"
          "d /run/ingest-secret 0555 root root -"
        ];

        systemd.services.ingest-emit = {
          description = "Ship ${id} NDJSON batches to the host writer over vsock";
          wantedBy = [ "multi-user.target" ];
          requires = [ "run-ingest-secret.mount" ];
          after = [
            "run-ingest-secret.mount"
            "systemd-tmpfiles-setup.service"
          ];
          restartIfChanged = false;
          environment = proxyEnv;
          serviceConfig = {
            Type = "simple";
            Restart = "always";
            RestartSec = "5s";
            UMask = "0077";
            ExecStart = "${emitter}/bin/ingest-emit --source ${id} --port ${toString s.vsockPort} --outbox /var/lib/ingest/outbox --secret /run/ingest-secret/env";
          };
        };

        system.stateVersion = "26.05";
      }
      (lib.mkIf (id == "search") {
        # The verifier's guest: one deterministic batch and a direct-egress probe. T15 replaces
        # both when the search service ships its own emitter.
        systemd.services.ingest-test-seed = {
          description = "Seed one deterministic batch for kanbei-ingest-verify";
          wantedBy = [ "multi-user.target" ];
          after = [ "systemd-tmpfiles-setup.service" ];
          before = [ "ingest-emit.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            UMask = "0077";
          };
          script = ''
            set -eu
            install -d -m 0700 /var/lib/ingest/outbox
            cat > /var/lib/ingest/outbox/000000-test.json <<'EOF'
            {"v":1,"source":"search","kind":"batch","seq":1,"sent_at":"1970-01-01T00:00:00Z","items":[{"probe":"kanbei-ingest-verify"}]}
            EOF
            chmod 0600 /var/lib/ingest/outbox/000000-test.json
          '';
        };

        systemd.services.ingest-egress-probe = {
          description = "Prove the guest cannot reach the internet directly";
          wantedBy = [ "multi-user.target" ];
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            set -u
            if ${pkgs.curl}/bin/curl --noproxy '*' --silent --show-error --max-time 3 \
                --output /dev/null http://1.1.1.1/ 2>/dev/null; then
              echo "INGEST-EGRESS-REACHED" > /dev/console
              exit 1
            fi
            echo "INGEST-EGRESS-DROPPED" > /dev/console
          '';
        };
      })
    ];

  prepScript = pkgs.writeShellScript "ingest-vm-prep" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ pkgs.coreutils ]}
    install -d -m 0700 ${constants.stateRoot}
    install -d -m 0700 ${constants.stateRoot}/state
    install -d -m 0700 ${constants.logDir}
    install -d -m 0755 -o root -g root ${constants.inboxDir}
    # Firecracker runs as microvm:kvm and must read the secret image; the directory stays out
    # of the guest-reachable 0700 state root so the group can traverse it.
    install -d -m 0750 -o root -g kvm /var/lib/microvms/ingest-secrets
  '';

  secretScript =
    id:
    let
      guest = sources.${id}.guest;
    in
    pkgs.writeShellScript "ingest-vm-secret-${id}" ''
      set -euo pipefail
      export PATH=${
        lib.makeBinPath [
          pkgs.coreutils
          pkgs.e2fsprogs
        ]
      }
      src=/run/secrets/${id}-env
      image=/var/lib/microvms/ingest-secrets/${id}.img
      sum="$image.sha256"
      if [ ! -r "$src" ]; then
        echo "ingest-vm-secret-${id}: missing $src; stage the ${id} secret (docs/manual-steps.md)" >&2
        exit 1
      fi
      want=$(sha256sum "$src" | cut -d' ' -f1)
      if [ -s "$sum" ] && [ "$(cat "$sum")" = "$want" ] && [ -e "$image" ]; then
        exit 0
      fi
      if ${config.systemd.package}/bin/systemctl is-active --quiet microvm@${guest}.service; then
        echo "ingest-vm-secret-${id}: refusing to replace the image under a running guest" >&2
        exit 1
      fi
      tmp=$(mktemp -d)
      trap 'rm -rf "$tmp"' EXIT
      # mkfs -d copies the directory, so the image lives outside it.
      root="$tmp/root"
      install -d -m 0700 "$root"
      install -m 0400 "$src" "$root/env"
      truncate -s 4M "$tmp/image"
      mkfs.ext4 -q -F -L "ingest-${id}-secret" -d "$root" "$tmp/image"
      install -m 0440 -o root -g kvm "$tmp/image" "$image"
      printf '%s\n' "$want" > "$sum"
      chmod 0400 "$sum"
    '';

  netScript =
    id:
    let
      f = ingest.factsFor id;
    in
    pkgs.writeShellScript "ingest-vm-net-${id}" ''
      set -eu
      ${pkgs.procps}/bin/sysctl -qw net.ipv6.conf.${f.tap}.disable_ipv6=1
      ${pkgs.iproute2}/bin/ip addr replace ${f.hostAddr}/30 dev ${f.tap}
      ${pkgs.iproute2}/bin/ip link set ${f.tap} up
    '';

  serviceSandbox = hardening // {
    ReadWritePaths = [
      constants.inboxDir
      constants.stateRoot
      constants.logDir
    ];
    RestrictAddressFamilies = [
      "AF_UNIX"
      "AF_INET"
      "AF_INET6"
      "AF_VSOCK"
    ];
    RestrictSUIDSGID = true;
    LockPersonality = true;
  };
in
{
  imports = [ inputs.microvm.nixosModules.host ];

  options.ingestVm.enable = lib.mkEnableOption "the Firecracker ingest plane and its host writer, proxy and resolver";

  config = lib.mkIf cfg.enable {
    microvm.vms = builtins.listToAttrs (
      map (id: {
        name = sources.${id}.guest;
        value = {
          autostart = true;
          restartIfChanged = false;
          config = guestFor id;
        };
      }) sourceIds
    );

    # Directories, policy, firewall table and the fixed-address taps.
    systemd.services = lib.mkMerge [
      {
        ingest-vm-prep = {
          description = "Create the ingest plane's root-only state, inbox and policy";
          wantedBy = [ "multi-user.target" ];
          before = [
            "ingest-vm-net-tuta.service"
          ]
          ++ map (id: "microvm@${sources.${id}.guest}.service") sourceIds;
          after = [ "local-fs.target" ];
          restartIfChanged = false;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = prepScript;
          };
        };

        ingest-age-key = {
          description = "Accept Kanbei's age recipient on the schema-locked vsock port";
          wantedBy = [
            "multi-user.target"
            "microvm@kanbei.service"
          ];
          after = [
            "microvm@kanbei.service"
            "ingest-vm-prep.service"
          ];
          wants = [
            "microvm@kanbei.service"
            "ingest-vm-prep.service"
          ];
          bindsTo = [ "microvm@kanbei.service" ];
          restartIfChanged = false;
          serviceConfig = serviceSandbox // {
            Type = "simple";
            Restart = "always";
            RestartSec = "2s";
            UMask = "0077";
            ExecStart = "${ingestAgeKey}/bin/ingest-age-key --uds ${kanbeiUds} --out ${recipientFile}";
            StandardOutput = "append:${constants.logDir}/ingest-age-key.log";
            StandardError = "append:${constants.logDir}/ingest-age-key.log";
            ReadWritePaths = [ "/var/lib/microvms/kanbei" ] ++ serviceSandbox.ReadWritePaths;
          };
        };

        ingest-proxy = {
          description = "Hostname/SNI-filtering HTTP(S) proxy for the ingest taps";
          wantedBy = [ "multi-user.target" ];
          after = [
            "ingest-vm-prep.service"
            "network.target"
          ];
          restartIfChanged = false;
          serviceConfig = serviceSandbox // {
            Type = "simple";
            Restart = "always";
            RestartSec = "3s";
            UMask = "0077";
            ExecStart = "${ingestProxy}/bin/ingest-proxy --policy ${constants.policyFile}";
            StandardOutput = "append:${constants.logDir}/ingest-proxy.log";
            StandardError = "append:${constants.logDir}/ingest-proxy.log";
          };
        };

        ingest-resolver = {
          description = "Allowlist-only DNS responder for the ingest taps";
          wantedBy = [ "multi-user.target" ];
          after = [
            "ingest-vm-prep.service"
            "network.target"
          ];
          restartIfChanged = false;
          serviceConfig = serviceSandbox // {
            Type = "simple";
            Restart = "always";
            RestartSec = "3s";
            UMask = "0077";
            ExecStart = "${ingestResolver}/bin/ingest-resolver --policy ${constants.policyFile}";
            StandardOutput = "append:${constants.logDir}/ingest-resolver.log";
            StandardError = "append:${constants.logDir}/ingest-resolver.log";
          };
        };

        ingest-heartbeat = {
          description = "Publish ingest freshness to Kanbei and alert on stale sources";
          after = [ "ingest-vm-prep.service" ];
          restartIfChanged = false;
          serviceConfig = serviceSandbox // {
            Type = "oneshot";
            UMask = "0077";
            ExecStart = "${ingestHeartbeat}/bin/ingest-heartbeat --policy ${constants.policyFile} --state-dir ${constants.stateRoot}/state --inbox ${constants.inboxDir} --recipient-file ${recipientFile} --retain-hours ${toString constants.heartbeatRetainHours}";
            StandardOutput = "append:${constants.logDir}/ingest-heartbeat.log";
            StandardError = "append:${constants.logDir}/ingest-heartbeat.log";
          };
        };
      }
      (builtins.listToAttrs (
        map (
          id:
          let
            s = sources.${id};
            f = ingest.factsFor id;
          in
          {
            name = "ingest-writer-${id}";
            value = {
              description = "Age-encrypt ${id} ingest batches into Kanbei's inbox";
              after = [
                "microvm@${s.guest}.service"
                "ingest-age-key.service"
                "ingest-vm-prep.service"
              ];
              wantedBy = [
                "multi-user.target"
                "microvm@${s.guest}.service"
              ];
              wants = [
                "microvm@${s.guest}.service"
                "ingest-age-key.service"
                "ingest-vm-prep.service"
              ];
              bindsTo = [ "microvm@${s.guest}.service" ];
              # A rejected batch or a vanished guest fails the unit; the alert path surfaces it.
              onFailure = [ "cloudflare-email@%n.service" ];
              restartIfChanged = false;
              # A rejected batch exits 65; do not hammer the guest or the mail path.
              unitConfig = {
                StartLimitBurst = 5;
                StartLimitIntervalSec = 300;
              };
              serviceConfig = serviceSandbox // {
                Type = "simple";
                Restart = "always";
                RestartSec = "5s";
                UMask = "0077";
                ExecStart = "${ingestWriter}/bin/ingest-writer --policy ${constants.policyFile} --source ${id} --vsock ${f.vmStateDir}/notify.vsock --guest-port ${toString s.vsockPort} --recipient-file ${recipientFile} --inbox ${constants.inboxDir} --state-dir ${constants.stateRoot}/state";
                StandardOutput = "append:${constants.logDir}/ingest-writer-${id}.log";
                StandardError = "append:${constants.logDir}/ingest-writer-${id}.log";
              };
            };
          }
        ) sourceIds
      ))
      (builtins.listToAttrs (
        lib.concatMap (
          id:
          let
            s = sources.${id};
          in
          [
            {
              name = "ingest-vm-secret-${id}";
              value = {
                description = "Stage the ${id} secret block device from /run/secrets/${id}-env";
                after = [ "ingest-vm-prep.service" ];
                before = [ "microvm@${s.guest}.service" ];
                requiredBy = [ "microvm@${s.guest}.service" ];
                restartIfChanged = false;
                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                  ExecStart = secretScript id;
                };
              };
            }
            {
              name = "ingest-vm-net-${id}";
              value = {
                description = "Address the ${s.guest} tap";
                after = [ "microvm-tap-interfaces@${s.guest}.service" ];
                bindsTo = [ "microvm-tap-interfaces@${s.guest}.service" ];
                before = [ "microvm@${s.guest}.service" ];
                requiredBy = [ "microvm@${s.guest}.service" ];
                restartIfChanged = false;
                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                  ExecStart = netScript id;
                };
              };
            }
          ]
        ) sourceIds
      ))
    ];

    environment.etc."kanbei-ingest/policy.json" = {
      mode = "0600";
      text = builtins.toJSON ingest.policy;
    };
    # `firewallUp` restores this exact text; the check asserts it is only the generated rules.
    environment.etc."kanbei-ingest/rules.v4" = {
      mode = "0600";
      text = firewallTable;
    };

    systemd.tmpfiles.rules = [
      "d ${constants.stateRoot} 0700 root root -"
      "d ${constants.stateRoot}/state 0700 root root -"
      "d ${constants.logDir} 0700 root root -"
      "d ${constants.inboxDir} 0755 root root -"
      "d /var/lib/microvms/ingest-secrets 0750 root kvm -"
    ];

    networking = {
      networkmanager.unmanaged = map (id: (ingest.factsFor id).tap) sourceIds;
      firewall.enable = true;
      firewall.extraCommands = firewallUp;
    };

    environment.systemPackages = [
      kanbeiLogs
      kanbeiIngestVerify
      ingestWriter
    ];

    assertions = [
      {
        assertion = config.networking.firewall.enable && !config.networking.nftables.enable;
        message = "ingest-vm: per-tap chains are iptables; the host must stay on iptables";
      }
      {
        assertion = config.kanbeiVm.enable or false;
        message = "ingest-vm: the writer encrypts to Kanbei's published key; enable kanbeiVm first";
      }
      {
        assertion = ingest.validateSources sources == [ ];
        message = "ingest-vm: a configured hostname is outside a source's permit table: ${lib.concatStringsSep "; " (ingest.validateSources sources)}";
      }
      {
        assertion = ingest.validateFacts sources == [ ];
        message = "ingest-vm: guest facts collide: ${lib.concatStringsSep "; " (ingest.validateFacts sources)}";
      }
      {
        assertion =
          ingest.validateFirewall {
            tbl = sources;
            rules = firewallTable;
          } == [ ];
        message = "ingest-vm: firewall rules allow more than proxy/resolver on a tap: ${
          lib.concatStringsSep "; " (
            ingest.validateFirewall {
              tbl = sources;
              rules = firewallTable;
            }
          )
        }";
      }
    ]
    ++ lib.concatMap (
      id:
      let
        s = sources.${id};
        guest = config.microvm.vms.${s.guest}.config.config;
        m = guest.microvm;
      in
      [
        {
          assertion = m.hypervisor == "firecracker";
          message = "ingest-vm: ${s.guest} must run on Firecracker";
        }
        {
          assertion =
            m.socket != null
            && m.shares == [ ]
            && m.devices == [ ]
            && builtins.length m.interfaces == 1
            && builtins.length m.volumes == 1
            && (builtins.head m.volumes).readOnly;
          message = "ingest-vm: ${s.guest} needs a socket, one tap and only a read-only secret volume (no shares, no devices)";
        }
        {
          assertion = m.vsock.cid == s.vsockCid;
          message = "ingest-vm: ${s.guest} vsock cid drifted from the shared table";
        }
        {
          assertion =
            config.systemd.services."ingest-writer-${id}".restartIfChanged == false
            && config.systemd.services."ingest-vm-net-${id}".restartIfChanged == false
            && config.systemd.services."ingest-vm-secret-${id}".restartIfChanged == false
            && config.microvm.vms.${s.guest}.restartIfChanged == false;
          message = "ingest-vm: prep/net/writer and the VM must not restart on a host switch";
        }
      ]
    ) sourceIds
    ++ [
      {
        assertion =
          !lib.any (
            i: lib.elem (ingest.factsFor i).tap (config.networking.nat.internalInterfaces or [ ])
          ) sourceIds;
        message = "ingest-vm: no ingest tap may be NATed; all egress is the host proxy";
      }
      {
        assertion =
          !(config.microvm.vms ? kanbei)
          || lib.all (
            id: (ingest.factsFor id).vsockCid != config.microvm.vms.kanbei.config.config.microvm.vsock.cid
          ) sourceIds;
        message = "ingest-vm: an ingest guest reuses Kanbei's vsock cid";
      }
      {
        assertion =
          lib.all
            (
              name:
              lib.hasInfix "append:${constants.logDir}/" (
                config.systemd.services.${name}.serviceConfig.StandardOutput or ""
              )
            )
            (
              map (id: "ingest-writer-${id}") sourceIds
              ++ [
                "ingest-proxy"
                "ingest-resolver"
                "ingest-age-key"
                "ingest-heartbeat"
              ]
            );
        message = "ingest-vm: every ingest unit writes a root-only file log";
      }
      {
        assertion = builtins.elem kanbeiLogs config.environment.systemPackages;
        message = "ingest-vm: the touch-gated kanbei-logs viewer must be installed";
      }
    ];
  };
}
