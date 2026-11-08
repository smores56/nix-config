# The Linux agent VM (smores56/sdlc#386): agents run in a microvm.nix NixOS guest, so nothing they
# do can reach the host's sudo, polkit, YubiKey or session sockets. `agent-sandbox maki`
# (modules/features/agent-vm) opens an SSH session into it.
#
# The guest sees $HOME at the same path through one virtiofs share of a host-assembled view
# (modules/lib/agent_view.py): everything but `deny`, read-only except `rw`. virtiofsd squashes
# every guest uid to the human's, so guest root cannot plant root-owned or setuid-root files.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.agentVm;
  ports = import ../ports.nix;
  user = config.machine.username;
  home = "/home/${user}";
  uid = 1000;
  gid = 100;

  vmLib = import ../lib/agent-vm.nix { inherit pkgs lib; };
  inherit (vmLib)
    name
    tap
    hostAddr
    guestAddr
    stateDir
    ;
  # Locally administered unicast, fixed so the guest's networkd match never changes.
  guestMac = "02:00:0a:4d:00:02";

  # microvm.nix keeps this image in its own state dir, named after the VM.
  storeImage = "${config.microvm.stateDir}/${name}/nix-store.img";

  runDir = "/run/agent-vm";
  view = "${runDir}/home";
  secretsDir = "${runDir}/secrets";
  authorizedKeys = "agent-vm-authorized-keys";
  # The agent's own XDG dirs (the launcher points XDG_*_HOME at them).
  agentDirs = [
    ".local/state/agent"
    ".local/share/agent"
    ".cache/agent"
  ];

  planner = ../lib/share_planner.py;
  viewBuilder = ../lib/agent_view.py;
  python = lib.getExe pkgs.python3;

  # Host loopback services the agent uses; both are token-authenticated.
  proxied = [
    ports.llm
    ports.memoryMcp
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

  prepScript = pkgs.writeShellScript "agent-vm-prep" ''
    set -euo pipefail
    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.util-linux
        pkgs.openssh
      ]
    }
    # A guest `nix store gc` unlinks paths it has registered. When the same path
    # exists in the host store, overlayfs records the unlink as a whiteout in the
    # guest's writable layer, hiding the host path from the guest permanently:
    # home-manager symlinks in the shared home (maki's init.lua among them) go
    # dangle and the agent silently runs without its managed config. Drop only
    # whiteouts that still mask a host path; guest-built paths have no lower
    # layer and stay. The image is mounted only while the guest is down, since
    # qemu holds it open otherwise.
    if ! systemctl is-active --quiet microvm@${name}.service && [ -f ${storeImage} ]; then
      storeMount=$(mktemp -d)
      if mount -o loop ${storeImage} "$storeMount"; then
        for entry in "$storeMount"/store/*; do
          [ -c "$entry" ] || continue
          entryName=$(basename "$entry")
          if [ -e "/nix/store/$entryName" ]; then rm -f "$entry"; fi
        done
        umount "$storeMount"
      fi
      rmdir "$storeMount"
    fi

    if mountpoint -q ${view}; then umount -R ${view}; fi
    rm -rf ${view} ${secretsDir}
    install -d -m 0711 ${runDir}
    install -d -m 0755 ${view}
    mount -t tmpfs -o mode=0755,nosuid,nodev,size=16m agent-vm-home ${view}

    # The planner shares only what exists, and the guest cannot create these under read-only
    # parents; made as the user, so no root write follows a path in the home.
    runuser -u ${user} -- mkdir -p ${lib.escapeShellArgs (map (rel: "${home}/${rel}") agentDirs)}

    # The planner only reads the home, so it runs as its owner; the root step trusts its JSON
    # for paths alone and re-checks every source with O_NOFOLLOW.
    runuser -u ${user} -- ${python} -I ${planner} --home ${home} \
      ${
        lib.escapeShellArgs (
          lib.concatMap (d: [
            "--deny"
            d
          ]) cfg.deny
          ++ lib.concatMap (r: [
            "--rw"
            r
          ]) cfg.rw
        )
      } \
      | ${python} -I ${viewBuilder} --home ${home} --view ${view}
    # Split dirs are tmpfs; read-only keeps the guest from leaving files beside the shares.
    # Each bind keeps its own flags.
    mount -o remount,ro ${view}

    # Root-owned so the user can read the launcher key but not swap either file for a symlink
    # that this root step would then copy into the guest.
    install -d -m 0755 -o root -g root ${stateDir}
    if [ ! -e ${stateDir}/id_ed25519 ]; then
      ssh-keygen -q -t ed25519 -N "" -C agent-vm -f ${stateDir}/id_ed25519
    fi
    chown root:root ${stateDir}/id_ed25519.pub
    chown ${user}:users ${stateDir}/id_ed25519
    chmod 0644 ${stateDir}/id_ed25519.pub
    chmod 0400 ${stateDir}/id_ed25519
    install -d -m 0755 ${secretsDir}
    install -m 0644 ${stateDir}/id_ed25519.pub ${secretsDir}/${authorizedKeys}
    for secret in ${lib.escapeShellArgs cfg.secrets}; do
      if [ -e "/run/secrets/$secret" ]; then
        install -m 0400 -o ${user} -g users "/run/secrets/$secret" "${secretsDir}/$secret"
      fi
    done
  '';

  netScript = pkgs.writeShellScript "agent-vm-net" ''
    set -eu
    ${pkgs.procps}/bin/sysctl -qw net.ipv6.conf.${tap}.disable_ipv6=1
    ${pkgs.iproute2}/bin/ip addr replace ${hostAddr}/30 dev ${tap}
    ${pkgs.iproute2}/bin/ip link set ${tap} up
  '';

  # Dedicated chains jumped to from the top of INPUT/FORWARD, ahead of nixos-fw and netavark.
  # iptables-restore --noflush replaces each chain's rules in one transaction and the jumps are
  # never removed (no extraStopCommands), so a firewall restart leaves tap traffic filtered.
  rules4 = pkgs.writeText "agent-vm-rules4" ''
    *filter
    :agent-vm-in - [0:0]
    :agent-vm-fwd - [0:0]
    -A agent-vm-in -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ${lib.concatMapStrings (port: ''
      -A agent-vm-in -d ${hostAddr} -p tcp --dport ${toString port} -j ACCEPT
    '') proxied}
    -A agent-vm-in -j DROP
    -A agent-vm-fwd -o ${tap} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    -A agent-vm-fwd -o ${tap} -j DROP
    ${lib.concatMapStrings (net: ''
      -A agent-vm-fwd -d ${net} -j DROP
    '') privateNets}
    -A agent-vm-fwd -j ACCEPT
    COMMIT
  '';
  rules6 = pkgs.writeText "agent-vm-rules6" ''
    *filter
    :agent-vm-in - [0:0]
    :agent-vm-fwd - [0:0]
    -A agent-vm-in -j DROP
    -A agent-vm-fwd -j DROP
    COMMIT
  '';
  firewallUp = ''
    iptables-restore -w --noflush ${rules4}
    ip6tables-restore -w --noflush ${rules6}
    for t in iptables ip6tables; do
      $t -w -C INPUT -i ${tap} -j agent-vm-in 2>/dev/null || $t -w -I INPUT 1 -i ${tap} -j agent-vm-in
      $t -w -C FORWARD -i ${tap} -j agent-vm-fwd 2>/dev/null || $t -w -I FORWARD 1 -i ${tap} -j agent-vm-fwd
      $t -w -C FORWARD -o ${tap} -j agent-vm-fwd 2>/dev/null || $t -w -I FORWARD 1 -o ${tap} -j agent-vm-fwd
    done
  '';

  proxySockets =
    listen: target:
    lib.listToAttrs (
      map (port: {
        name = "agent-vm-proxy-${toString port}";
        value = {
          socket = {
            wantedBy = [ "sockets.target" ];
            socketConfig = {
              ListenStream = "${listen}:${toString port}";
              # The listen address may appear after the socket unit starts (the host tap).
              FreeBind = true;
            };
          };
          service = {
            serviceConfig = {
              ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd ${target}:${toString port}";
              DynamicUser = true;
              PrivateTmp = true;
              ProtectSystem = "strict";
              ProtectHome = true;
              NoNewPrivileges = true;
            };
          };
        };
      }) proxied
    );
  hostProxies = proxySockets hostAddr "127.0.0.1";

  # The guest has no SSH agent: the human's ~/.ssh/config would offer YubiKey identities that
  # cannot sign there. A laptop guest reaches smortress with the personal signing key, whose
  # forced command lands in smortress's own guest (modules/nixos/ssh.nix).
  isServer = builtins.elem "server" config.machine.profiles;
  guestSshConfig = ''
    ${lib.optionalString (!isServer) ''
      Host smortress
        HostName smortress
        User ${user}
        ProxyCommand cloudflared-access ssh --hostname %h
        IdentityFile /run/secrets/github-personal-signing-key
    ''}
    Host *
      IdentitiesOnly yes
      IdentityAgent none
      ForwardAgent no
      ControlMaster no
      UserKnownHostsFile ${home}/.local/state/agent/known_hosts
  '';
  # Ahead of the home profile on the guest PATH (the launcher puts /run/current-system first).
  guestSsh = pkgs.writeShellScriptBin "ssh" ''
    exec ${pkgs.openssh}/bin/ssh -F /etc/agent-vm/ssh_config "$@"
  '';

  guest =
    { lib, pkgs, ... }:
    let
      guestProxies = proxySockets "127.0.0.1" hostAddr;
    in
    {
      microvm = {
        hypervisor = "qemu";
        # microvm.nix otherwise loads the guest's closure into the guest's Nix DB
        # with `nix-store --load-db` on every boot. A guest `nix store gc` then
        # deletes those host-store paths, and the overlay keeps each deletion as a
        # whiteout masking the host's copy (see the prep script above). The guest
        # reads /nix/store directly, so it does not need its closure registered.
        registerClosure = false;
        inherit (cfg) vcpu mem;
        interfaces = [
          {
            type = "tap";
            id = tap;
            mac = guestMac;
          }
        ];
        # Guest uids all write as the human: guest root cannot chown to root or plant a setuid-root
        # file in a writable tree. No --xattr (posixAcl off), so no file capabilities either.
        virtiofsd.extraArgs = [
          "--translate-uid=squash-guest:0:${toString uid}:4294967295"
          "--translate-gid=squash-guest:0:${toString gid}:4294967295"
          # virtiofsd runs as root: without CAP_MKNOD guest root cannot plant device nodes in the
          # writable trees or the extra shares, whose real host paths are not nodev.
          "--modcaps=-mknod"
        ];
        shares =
          map
            (
              s:
              s
              // {
                proto = "virtiofs";
                posixAcl = false;
              }
            )
            (
              [
                {
                  tag = "ro-store";
                  source = "/nix/store";
                  mountPoint = "/nix/.ro-store";
                  readOnly = true;
                }
                {
                  tag = "home";
                  source = view;
                  mountPoint = home;
                }
                {
                  tag = "secrets";
                  source = secretsDir;
                  mountPoint = "/run/secrets";
                  readOnly = true;
                }
              ]
              ++ lib.imap0 (i: share: {
                tag = "extra${toString i}";
                source = share.path;
                mountPoint = share.path;
                inherit (share) readOnly;
              }) cfg.extraShares
            );
        # Builds stay in the guest: the host daemon would run fixed-output fetches on the host's
        # own network, past the firewall below.
        writableStoreOverlay = "/nix/.rw-store";
        volumes = [
          {
            image = "var.img";
            mountPoint = "/var";
            size = 65536;
          }
          {
            image = "nix-store.img";
            mountPoint = "/nix/.rw-store";
            size = 65536;
          }
        ];
      };

      networking = {
        hostName = "agent-vm";
        useNetworkd = true;
        nameservers = [
          "1.1.1.1"
          "9.9.9.9"
        ];
        firewall.allowedTCPPorts = [ 22 ];
      };
      systemd.network.networks."10-tap" = {
        matchConfig.MACAddress = guestMac;
        address = [ "${guestAddr}/30" ];
        routes = [ { Gateway = hostAddr; } ];
        networkConfig.IPv6AcceptRA = false;
        linkConfig.RequiredForOnline = "routable";
      };
      boot.kernel.sysctl."net.ipv6.conf.all.disable_ipv6" = 1;

      users.users.${user} = {
        inherit uid home;
        isNormalUser = true;
        group = "users";
        createHome = false;
        extraGroups = [
          "wheel"
          "docker"
        ];
      };
      # The guest is the boundary; root in it reaches nothing the user could not.
      security.sudo.wheelNeedsPassword = false;

      services.openssh = {
        enable = true;
        # /etc is rebuilt every boot; /var persists, so the launcher's known_hosts stays valid.
        hostKeys = [
          {
            path = "/var/lib/ssh/ssh_host_ed25519_key";
            type = "ed25519";
          }
        ];
        # A root-owned copy on the read-only secrets share, not a path in the shared home.
        authorizedKeysFiles = lib.mkForce [ "/run/secrets/${authorizedKeys}" ];
        settings = {
          PasswordAuthentication = false;
          KbdInteractiveAuthentication = false;
          PermitRootLogin = "no";
          AllowUsers = [ user ];
          AllowAgentForwarding = false;
          AllowTcpForwarding = "no";
          AllowStreamLocalForwarding = "no";
          X11Forwarding = false;
          PermitUserRC = false;
          AcceptEnv = [
            "COLORTERM"
            "TERM"
          ];
        };
      };

      virtualisation.docker.enable = true;
      nix.settings = {
        experimental-features = [
          "nix-command"
          "flakes"
        ];
        trusted-users = [ user ];
      };
      environment.systemPackages = [ guestSsh ];
      environment.etc."agent-vm/ssh_config".text = guestSshConfig;

      # Files a tool must rewrite under a read-only share get a guest-local copy bound over them.
      systemd.services = lib.mapAttrs (_: v: v.service) guestProxies // {
        agent-vm-writable = {
          wantedBy = [ "multi-user.target" ];
          after = [ "local-fs.target" ];
          before = [ "sshd.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          path = [
            pkgs.coreutils
            pkgs.util-linux
          ];
          script = lib.concatMapStrings (rel: ''
            src=${home}/${rel}
            copy=/var/lib/agent-vm/writable/${rel}
            if [ -f "$src" ] && ! mountpoint -q "$src"; then
              install -D -m 0644 -o ${user} -g users "$src" "$copy"
              mount --bind "$copy" "$src"
            fi
          '') cfg.guestWritable;
        };
      };
      systemd.sockets = lib.mapAttrs (_: v: v.socket) guestProxies;

      system.stateVersion = "26.05";
    };
in
{
  imports = [ inputs.microvm.nixosModules.host ];

  options.agentVm = {
    deny = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "Home-relative paths the guest never sees.";
    };
    rw = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "Home-relative paths shared read-write; everything else shared is read-only.";
    };
    extraShares = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            path = lib.mkOption { type = lib.types.str; };
            readOnly = lib.mkOption {
              type = lib.types.bool;
              default = true;
            };
          };
        }
      );
      default = [ ];
      description = "Paths outside the home shared at the same path.";
    };
    secrets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "sops secrets (names under /run/secrets) handed to the guest at the same path.";
    };
    guestWritable = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Home-relative files under read-only shares that get a guest-local writable copy.";
    };
    vcpu = lib.mkOption {
      type = lib.types.int;
      default = 4;
    };
    mem = lib.mkOption {
      type = lib.types.int;
      default = 8192;
      description = "Guest RAM in MiB.";
    };
  };

  config = {
    agentVm = lib.mapAttrs (_: lib.mkDefault) {
      deny = [
        ".config/sops"
        ".config/BraveSoftware"
        ".cache/BraveSoftware"
        ".config/chromium"
        ".cache/chromium"
        ".config/mozilla"
        ".cache/mozilla"
        ".mozilla"
        ".config/tutanota-desktop"
        ".config/Bitwarden"
        ".local/share/keyrings"
        ".local/share/ykman"
        ".local/state/key-backup"
        ".local/share/proton-pass-cli"
        ".local/state/proton"
        ".cache/cliphist"
        ".gnupg"
        ".pki"
        ".var/app"
        ".steam"
        ".local/share/Steam"
        # `sudo vault` and the todo bindfs are the only ways in; the guest has
        # neither sudo nor the mounts.
        ".local/share/vault"
        ".local/share/todo"
        # The Syncthing state dir holds the device key, the GUI API key, and the
        # vault's retired identity copy.
        ".local/state/syncthing"
      ];
      rw = [
        "repos"
        "dev"
        "Documents"
        "Downloads"
        ".cargo/registry"
        ".cargo/git"
        ".npm"
        ".bun/install/cache"
      ]
      # The human's state is never extended, and guest sessions survive restarts.
      ++ agentDirs;
      secrets = [
        "github-personal-pat"
        "github-personal-signing-key"
        "memory-mcp-token"
        "neuralwatt-api-key"
        "tinyfish-api-key"
        "immich-agent-api-key"
        "cloudflare-access-ssh-token"
      ];
      guestWritable = [ ".config/maki/pack-lock.json.lock" ];
    };

    microvm.vms.${name} = {
      autostart = true;
      # A host switch must not kill running agent sessions; `agent-sandbox restart` says how to
      # pick up a changed guest.
      restartIfChanged = false;
      config = guest;
    };

    systemd.services = {
      agent-vm-prep = {
        description = "Assemble the agent VM's home view and hand-in secrets";
        before = [
          "microvm-virtiofsd@${name}.service"
          "microvm@${name}.service"
        ];
        requiredBy = [ "microvm-virtiofsd@${name}.service" ];
        partOf = [ "microvm@${name}.service" ];
        after = [ "local-fs.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = prepScript;
          ExecStop = "-${pkgs.util-linux}/bin/umount -R ${view}";
        };
      };
      agent-vm-net = {
        description = "Address the agent VM's tap";
        after = [ "microvm-tap-interfaces@${name}.service" ];
        bindsTo = [ "microvm-tap-interfaces@${name}.service" ];
        before = [ "microvm@${name}.service" ];
        requiredBy = [ "microvm@${name}.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = netScript;
        };
      };
    }
    // lib.mapAttrs (_: v: v.service) hostProxies;
    systemd.sockets = lib.mapAttrs (_: v: v.socket) hostProxies;

    assertions = [
      {
        assertion = config.networking.firewall.enable && !config.networking.nftables.enable;
        message = "agent-vm isolates the tap with iptables firewall extraCommands";
      }
      {
        assertion = lib.all (
          pair: lib.elem (lib.removePrefix "/run/secrets/" (lib.last (lib.splitString "|" pair))) cfg.secrets
        ) vmLib.secretEnv;
        message = "agent-vm: every secret the launcher exports must be in agentVm.secrets";
      }
    ];

    # microvm.nix allows qemu-bridge-helper onto every bridge; this VM uses a plain tap.
    environment.etc."qemu/bridge.conf".text = "deny all\n";

    networking = {
      nat = {
        enable = true;
        internalInterfaces = [ tap ];
      };
      networkmanager.unmanaged = [ tap ];
      firewall = {
        extraCommands = firewallUp;
      };
    };
  };
}
