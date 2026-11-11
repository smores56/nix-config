# The `kanbei` guest (smores56/sdlc#584, part of #509): the private-data VM. qemu, no NIC, the
# RTX 3090 passed through by VFIO, and a LUKS2 data volume sealed to a per-VM software TPM whose
# state stays on the host. This module owns both sides: the guest NixOS config and the host
# plumbing (VFIO binding, swtpm, console, backup).
#
# Everything is behind `kanbeiVm.enable` (default false). Until the one-time cutover in
# docs/kanbei-vm.md the host still runs Immich/photo-triage on the 3090, so enabling is a
# deliberate operator action; with it enabled the nvidia/llm/photo-triage modules go inert
# (T9 deletes the files, this module only switches them off).
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.kanbeiVm;

  # `index` only names the state paths here (no tap: the guest has no interface).
  facts = import ../lib/vm-host.nix {
    name = "kanbei";
    index = 2;
    vsockCid = 4;
  };

  inherit (facts) stateDir vmStateDir;
  # Root-only: swtpm NVRAM is the seal for the guest disk.
  swtpmDir = "${stateDir}/swtpm";
  # qemu runs as `microvm:kvm`, so the socket directory is group-traversable but not world.
  runDir = "/run/kanbei-vm";
  swtpmSock = "${runDir}/swtpm.sock";
  swtpmCtrl = "${runDir}/swtpm.ctrl";
  # systemd opens these as root before dropping to `microvm`; the parent is 0700 root.
  consoleDir = "${stateDir}/console";
  consoleFile = "${consoleDir}/console.log";
  secretDir = "${stateDir}/secrets";
  # The guest writes the first-boot recovery key here before it formats the volume; root-only,
  # never part of a backup.
  enrollDir = "${stateDir}/enroll";
  inboxDir = "${stateDir}/inbox";

  # Discovered from the running host (`lspci -nn`, /sys/bus/pci/devices):
  # 0000:08:00.0 10de:2204 = RTX 3090, 0000:08:00.1 10de:1aef = its HDA function.
  # Both sit alone in IOMMU group 16, so no ACS override is needed.
  pci = {
    iommuGroup = 16;
    devices = [
      {
        path = "0000:08:00.0";
        id = "10de:2204";
        name = "RTX 3090";
      }
      {
        path = "0000:08:00.1";
        id = "10de:1aef";
        name = "GA102 HD Audio";
      }
    ];
  };
  vfioIds = lib.concatMapStringsSep "," (d: d.id) pci.devices;
  vfioParam = "vfio-pci.ids=${vfioIds}";

  # The guest's payload user (T11 runs the service as it) so the rw shares land as `vault` on
  # the host instead of host root. Guest root maps to `nobody`, like the cluster guest.
  guestUid = 1000;
  vaultId = 981;
  dataTranslation = [
    "--translate-uid=guest:0:65534:1"
    "--translate-uid=guest:${toString guestUid}:${toString vaultId}:1"
    "--translate-gid=guest:0:65534:1"
    "--translate-gid=guest:${toString guestUid}:${toString vaultId}:1"
    "--modcaps=-mknod"
  ];

  volumeSizeMiB = 65536;
  image = "${vmStateDir}/data.img";
  dataDevice = "/dev/disk/by-id/virtio-kanbei-data";

  # Not the generated `systemd-cryptenroll` recovery key: the operator-owned contract path.
  recoveryKeyFile = "/run/secrets/kanbei-recovery-key";

  vaultShares = [
    {
      tag = "vault";
      source = "/var/lib/data/vault";
      mountPoint = "/mnt/kanbei/vault";
      proto = "virtiofs";
      readOnly = true;
      posixAcl = false;
      extraArgs = dataTranslation;
    }
    {
      tag = "todo";
      source = "/var/lib/data/todo";
      mountPoint = "/mnt/kanbei/todo";
      proto = "virtiofs";
      posixAcl = false;
      extraArgs = dataTranslation;
    }
  ];

  hostStoreShare = {
    tag = "ro-store";
    source = "/nix/store";
    mountPoint = "/nix/store";
    proto = "virtiofs";
    readOnly = true;
  };

  # First boot: the volume has no LUKS header, so the recovery credential is created *before*
  # the format and escrowed on the host (contract file when sops provides one). A crash between
  # format and enrollment therefore never strands the volume.
  guestInit = pkgs.writeShellScript "kanbei-data-init" ''
    set -euo pipefail
    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.cryptsetup
        pkgs.systemd
        pkgs.tpm2-tools
      ]
    }
    dev=${dataDevice}
    for _ in $(seq 1 120); do
      [ -e "$dev" ] && break
      sleep 0.5
    done
    if [ ! -e "$dev" ]; then
      echo "kanbei-data-init: $dev did not appear" >&2
      exit 1
    fi
    if cryptsetup isLuks "$dev"; then
      exit 0
    fi

    umask 077
    contract=/run/kanbei-secrets/kanbei-recovery-key
    if [ -r "$contract" ]; then
      install -m 0400 "$contract" /run/kanbei-recovery.key
      generated=0
    elif [ -r /mnt/kanbei-enroll/recovery.key ]; then
      # A previous boot formatted but never finished enrolling.
      install -m 0400 /mnt/kanbei-enroll/recovery.key /run/kanbei-recovery.key
      generated=0
    else
      head -c 64 /dev/urandom > /run/kanbei-recovery.key
      # Escrow before formatting so a failed enrollment is always recoverable.
      install -m 0600 /run/kanbei-recovery.key /mnt/kanbei-enroll/recovery.key
      generated=1
    fi

    cryptsetup luksFormat --type luks2 --batch-mode --label KANBEI \
      --key-file /run/kanbei-recovery.key "$dev"
    # TPM2 token plus, when no contract key exists, systemd's generated recovery key.
    if [ "$generated" = 1 ]; then
      systemd-cryptenroll --tpm2-device=auto --recovery-key \
        --unlock-key-file=/run/kanbei-recovery.key "$dev" > /dev/console
    else
      systemd-cryptenroll --tpm2-device=auto \
        --unlock-key-file=/run/kanbei-recovery.key "$dev"
    fi

    cryptsetup open --key-file /run/kanbei-recovery.key "$dev" kanbei-data-init
    ${pkgs.e2fsprogs}/bin/mkfs.ext4 -q -L kanbei-data -m 1 /dev/mapper/kanbei-data-init
    cryptsetup close kanbei-data-init

    if [ "$generated" = 1 ]; then
      echo "kanbei: recovery key is in /var/lib/kanbei-vm/enroll/recovery.key (root-only) and was printed to the console; store it off-host and delete the escrow file" > /dev/console
    fi
  '';

  freezeScript = pkgs.writeShellScript "kanbei-vm-freeze" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ pkgs.coreutils ]}
    systemctl=${config.systemd.package}/bin/systemctl
    # A dirty image would restore an inconsistent LUKS filesystem, so refuse to snapshot a
    # running guest. Only restart what this hook stopped.
    if "$systemctl" is-active --quiet microvm@kanbei.service; then
      install -m 0600 /dev/null ${runDir}/backup-was-active
      "$systemctl" stop microvm@kanbei.service
    fi
    if "$systemctl" is-active --quiet microvm@kanbei.service; then
      echo "kanbei-vm-freeze: microvm@kanbei.service is still running" >&2
      exit 1
    fi
  '';

  thawScript = pkgs.writeShellScript "kanbei-vm-thaw" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ pkgs.coreutils ]}
    systemctl=${config.systemd.package}/bin/systemctl
    if [ -e ${runDir}/backup-was-active ]; then
      rm -f ${runDir}/backup-was-active
      "$systemctl" start microvm@kanbei.service || true
    fi
  '';

  # Runtime half of the "clean IOMMU group" check: evaluation only sees the recorded facts.
  verifyScript = pkgs.writeShellScript "kanbei-vm-verify" ''
    set -eu
    # The unit runs without the login PATH; the script also works from a root shell.
    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.kmod
      ]
    }
    fail=0
    expected="${lib.concatStringsSep " " (map (d: d.path) pci.devices)}"
    for p in $expected; do
      drv=$(basename "$(readlink -f "/sys/bus/pci/devices/$p/driver" 2>/dev/null || echo none)")
      if [ "$drv" = "vfio-pci" ]; then
        echo "ok: $p -> vfio-pci"
      else
        echo "FAIL: $p -> $drv (expected vfio-pci)" >&2
        fail=1
      fi
    done
    got=$(ls /sys/kernel/iommu_groups/${toString pci.iommuGroup}/devices | sort | tr '\n' ' ')
    if [ "$(echo $got)" != "$(echo $expected)" ]; then
      echo "FAIL: IOMMU group ${toString pci.iommuGroup} holds '$got', expected '$expected'" >&2
      fail=1
    fi
    if ${pkgs.kmod}/bin/lsmod | ${pkgs.gnugrep}/bin/grep -q '^nvidia'; then
      echo "FAIL: an nvidia module is loaded while the guest owns the GPU" >&2
      fail=1
    fi
    for p in ${swtpmDir} ${consoleDir}; do
      if [ "$(${pkgs.coreutils}/bin/stat -c %a "$p")" != "700" ]; then
        echo "FAIL: $p is not 0700" >&2
        fail=1
      fi
    done
    if [ ! -S ${swtpmSock} ]; then
      echo "FAIL: ${swtpmSock} is missing" >&2
      fail=1
    fi
    if [ ! -c /dev/vhost-vsock ]; then
      echo "FAIL: /dev/vhost-vsock is missing; vhost_vsock is not loaded" >&2
      fail=1
    fi
    exit "$fail"
  '';

  guest =
    { lib, ... }:
    {
      microvm = {
        hypervisor = "qemu";
        vcpu = 8;
        mem = 8192;
        # The guest reads /nix/store through the share; registering the closure would let a
        # guest `nix store gc` unlink host paths it never owned.
        registerClosure = false;
        # No interface at all: the only host path in is a future vsock relay (T11).
        interfaces = [ ];
        vsock.cid = facts.vsockCid;
        devices = map (d: {
          bus = "pci";
          inherit (d) path;
        }) pci.devices;
        shares = [
          hostStoreShare
          {
            tag = "inbox";
            source = inboxDir;
            mountPoint = "/mnt/kanbei/inbox";
            proto = "virtiofs";
            readOnly = true;
          }
          {
            tag = "kanbei-secrets";
            source = secretDir;
            mountPoint = "/run/kanbei-secrets";
            proto = "virtiofs";
            readOnly = true;
          }
          {
            tag = "kanbei-enroll";
            source = enrollDir;
            mountPoint = "/mnt/kanbei-enroll";
            proto = "virtiofs";
          }
        ]
        ++ vaultShares;
        # The raw image is created by preStart (no mkfs: LUKS2 owns it).
        volumes = [
          {
            inherit image;
            mountPoint = null;
            serial = "kanbei-data";
            size = volumeSizeMiB;
            autoCreate = false;
          }
        ];
        preStart = ''
          img=${lib.escapeShellArg image}
          if [ ! -e "$img" ]; then
            ${pkgs.coreutils}/bin/truncate -s ${toString volumeSizeMiB}M "$img"
            ${pkgs.coreutils}/bin/chmod 0600 "$img"
          fi
          i=0
          while [ "$i" -lt 150 ]; do
            [ -S ${swtpmSock} ] && break
            ${pkgs.coreutils}/bin/sleep 0.2
            i=$((i + 1))
          done
          if [ ! -S ${swtpmSock} ]; then
            echo "kanbei: ${swtpmSock} is missing; refusing to boot without the vTPM" >&2
            exit 1
          fi
        '';
        # microvm.nix has no vTPM option: the host unit owns swtpm and this connects QEMU to it.
        # `-monitor none` keeps the guest from ever reaching the QEMU monitor.
        qemu.extraArgs = [
          "-chardev"
          "socket,id=chrtpm,path=${swtpmSock}"
          "-tpmdev"
          "emulator,id=tpm0,chardev=chrtpm"
          "-device"
          "tpm-crb,tpmdev=tpm0"
          "-monitor"
          "none"
        ];
      };

      # No PCR policy (systemd's default): under direct kernel boot there is no measured boot, so
      # the separately enforced seal is the swtpm's own state (SRK/NVRAM). A guest kernel rebuild
      # therefore cannot invalidate the token; losing the swtpm state does (recovery key).
      boot.kernelModules = [
        "tpm"
        "tpm_crb"
        "vsock"
        "vmw_vsock_virtio_transport"
      ];
      security.tpm2.enable = true;

      networking = {
        hostName = facts.name;
        # No NIC; there is nothing to configure and no time source.
        useNetworkd = false;
        firewall.enable = false;
      };
      services.timesyncd.enable = false;

      environment.systemPackages = [
        pkgs.cryptsetup
        pkgs.tpm2-tools
      ];

      environment.etc.crypttab.text = ''
        kanbei-data ${dataDevice} none luks,tpm2-device=auto
      '';
      fileSystems."/var/lib/kanbei" = {
        device = "/dev/mapper/kanbei-data";
        fsType = "ext4";
        options = [
          "nodev"
          "nosuid"
          "noatime"
          "x-systemd.before=kanbei.service"
        ];
      };

      systemd.tmpfiles.rules = [
        "d /var/lib/kanbei 0700 root root -"
        "d /run/kanbei-secrets 0755 root root -"
      ];

      systemd.services.kanbei-data-init = {
        description = "Format and enroll the kanbei data volume on first boot";
        wantedBy = [ ];
        # The .device unit binds systemd-cryptsetup; this must win the race on first boot.
        requiredBy = [ "systemd-cryptsetup@kanbei-data.service" ];
        before = [
          "systemd-cryptsetup@kanbei-data.service"
          "kanbei.service"
        ];
        after = [ "systemd-udevd.service" ];
        # The escrow and the recovery-key contract are virtiofs shares; without them the
        # first-boot format has nowhere to put the credential, so fail instead of formatting.
        unitConfig.RequiresMountsFor = [
          "/mnt/kanbei-enroll"
          "/run/kanbei-secrets"
        ];
        restartIfChanged = false;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          UMask = "0077";
          ExecStart = guestInit;
        };
      };

      system.stateVersion = "26.05";
    };
in
{
  imports = [ inputs.microvm.nixosModules.host ];

  options.kanbeiVm.enable = lib.mkEnableOption "the kanbei private-data guest (VFIO GPU, LUKS data volume, software TPM)";

  config = lib.mkIf cfg.enable {
    # Bind the 3090 and its audio function to vfio-pci before any in-tree driver can claim them,
    # so the GPU is never touched by nvidia while the guest owns it.
    boot.kernelParams = [
      "amd_iommu=on"
      "iommu=pt"
      vfioParam
    ];
    boot.initrd.kernelModules = [
      "vfio"
      "vfio_iommu_type1"
      "vfio_pci"
    ];
    boot.extraModprobeConfig = ''
      softdep snd_hda_intel pre: vfio-pci
    '';
    # The guest's only host-facing device. Without it qemu cannot add vhost-vsock-pci.
    boot.kernelModules = [ "vhost_vsock" ];

    microvm.vms.${facts.name} = {
      autostart = true;
      # A host switch must not bounce the private-data guest; `systemctl restart microvm@kanbei`
      # is the explicit path (and the backup hook's).
      restartIfChanged = false;
      config = guest;
    };

    # Root-only state: swtpm NVRAM, the console log, the sops contract, the recovery escrow and
    # the inbox. The microvm.nix state dir holds the ciphertext image; it is 0700 `microvm` so no
    # login user can read it (documented residual: `microvm` is a nologin system account).
    systemd.tmpfiles.rules = [
      "d ${stateDir} 0700 root root -"
      "d ${swtpmDir} 0700 root root -"
      "d ${consoleDir} 0700 root root -"
      "d ${secretDir} 0700 root root -"
      "d ${enrollDir} 0700 root root -"
      "d ${inboxDir} 0755 root root -"
    ];

    systemd.services.kanbei-vm-prep = {
      description = "Create the kanbei guest's root-only state and escrow directories";
      before = [
        "kanbei-swtpm.service"
        "microvm-virtiofsd@${facts.name}.service"
        "microvm@${facts.name}.service"
      ];
      requiredBy = [ "microvm-virtiofsd@${facts.name}.service" ];
      partOf = [ "microvm@${facts.name}.service" ];
      restartIfChanged = false;
      after = [ "local-fs.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail
        install -d -m 0700 -o root -g root ${stateDir} ${swtpmDir} ${consoleDir} ${secretDir} ${enrollDir}
        install -d -m 0755 -o root -g root ${inboxDir}
        install -d -m 0700 -o microvm -g kvm ${vmStateDir}
        # sops contract: the operator's own recovery credential, not the generated one.
        if [ -r ${recoveryKeyFile} ]; then
          install -m 0400 -o root -g root ${recoveryKeyFile} ${secretDir}/kanbei-recovery-key
        fi
      '';
    };

    # microvm.nix has no vTPM option: swtpm owns the persistent state, QEMU connects to the
    # socket in extraArgs above. Running it as root keeps the NVRAM out of the VM user's reach.
    systemd.services.kanbei-swtpm = {
      description = "Software TPM for the kanbei guest (persistent root-only state)";
      requiredBy = [ "microvm@${facts.name}.service" ];
      before = [ "microvm@${facts.name}.service" ];
      after = [ "kanbei-vm-prep.service" ];
      requires = [ "kanbei-vm-prep.service" ];
      restartIfChanged = false;
      serviceConfig = {
        Type = "simple";
        User = "root";
        Group = "kvm";
        RuntimeDirectory = "kanbei-vm";
        RuntimeDirectoryMode = "0750";
        RuntimeDirectoryPreserve = "restart";
        ExecStart = "${pkgs.swtpm}/bin/swtpm socket --tpm2 --tpmstate dir=${swtpmDir} --ctrl type=unixio,path=${swtpmCtrl},mode=0660 --socket type=unixio,path=${swtpmSock},mode=0660";
        # One client, but a restart must leave the state (and the seal) intact.
        Restart = "always";
        RestartSec = "2s";
        UMask = "0077";
      };
    };

    # The guest console is the only place a first-boot recovery key is printed, so it has to be
    # readable when the guest is not. systemd opens the file as root before dropping to `microvm`
    # and the 0700 parent keeps every other login user out.
    systemd.services."microvm@${facts.name}" = {
      requires = [
        "kanbei-swtpm.service"
        "kanbei-vm-prep.service"
      ];
      after = [
        "kanbei-swtpm.service"
        "kanbei-vm-prep.service"
      ];
      restartIfChanged = false;
      serviceConfig = {
        StandardOutput = "append:${consoleFile}";
        UMask = "0077";
      };
    };

    environment.systemPackages = [ verifyScript ];
    systemd.services.kanbei-vm-verify = {
      description = "Verify the kanbei guest's VFIO binding, IOMMU group and root-only state";
      wantedBy = [ "multi-user.target" ];
      after = [
        "microvm@${facts.name}.service"
        "kanbei-swtpm.service"
      ];
      wants = [ "microvm@${facts.name}.service" ];
      restartIfChanged = false;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = verifyScript;
      };
    };

    # Restic freezes the guest first: the image is a live LUKS filesystem otherwise. Both repos
    # walk only the ciphertext image; swtpm state and the escrow are never backed up.
    services.restic.backups = {
      kanbei-r2 = {
        repository = "s3:https://${config.alerting.accountId}.r2.cloudflarestorage.com/restic-backup";
        environmentFile = config.sops.templates."restic-r2.env".path;
        initialize = true;
        paths = [ image ];
        exclude = [ swtpmDir ];
        backupPrepareCommand = "${freezeScript}";
        backupCleanupCommand = "${thawScript}";
        passwordFile = config.sops.secrets.restic-password.path;
        pruneOpts = [
          "--keep-daily 7"
          "--keep-weekly 4"
        ];
        timerConfig = {
          # The host-wide job owns 03:30; the guest is down for this one.
          OnCalendar = "*-*-* 02:30:00";
          RandomizedDelaySec = "10m";
          Persistent = true;
        };
      };
      kanbei-local = {
        repository = "/var/backup/restic";
        paths = [ image ];
        exclude = [ swtpmDir ];
        backupPrepareCommand = "${freezeScript}";
        backupCleanupCommand = "${thawScript}";
        passwordFile = config.sops.secrets.restic-password.path;
        pruneOpts = [
          "--keep-daily 7"
          "--keep-weekly 4"
        ];
        timerConfig = {
          OnCalendar = "*-*-* 02:40:00";
          RandomizedDelaySec = "10m";
          Persistent = true;
        };
      };
    };

    # The local repo lives on the backup disk: wait for that mount, or a missing disk would
    # quietly fill the root filesystem instead of failing.
    systemd.services."restic-backups-kanbei-local".unitConfig.RequiresMountsFor = [ "/var/backup" ];

    assertions = [
      {
        assertion = vfioIds == "10de:2204,10de:1aef";
        message = "kanbei-vm: vfio-pci.ids must name exactly the discovered GPU and audio functions (10de:2204,10de:1aef)";
      }
      {
        # The recorded group is what makes "no ACS override" true; a new device in it (or a
        # moved GPU) must be re-discovered, not guessed. Runtime check: kanbei-vm-verify.
        assertion = lib.all (d: lib.hasPrefix "0000:08:00." d.path) pci.devices;
        message = "kanbei-vm: the passthrough devices must be the recorded IOMMU group 16 pair (0000:08:00.0/.1)";
      }
      {
        assertion =
          !(lib.elem "nvidia" config.boot.kernelModules)
          && !(lib.elem "nvidia" config.services.xserver.videoDrivers)
          && !(config.systemd.services ? nvidia-uvm)
          && !(config.systemd.services ? llama-cpp);
        message = "kanbei-vm: the enabled host must not load nvidia or run llama-cpp; nvidia.nix/llm.nix/photo-triage.nix must stay inert while the guest owns the GPU";
      }
      {
        assertion =
          !lib.any (v: (v.config.config.microvm.vsock.cid or null) == facts.vsockCid) (
            lib.attrValues (lib.filterAttrs (n: _: n != facts.name) config.microvm.vms)
          );
        message = "kanbei-vm: vsock cid ${toString facts.vsockCid} must be unique across guests";
      }
      {
        assertion = lib.all (
          vm:
          !lib.any (d: lib.elem d.path (map (x: x.path) pci.devices)) (
            vm.config.config.microvm.devices or [ ]
          )
        ) (lib.attrValues (lib.filterAttrs (n: _: n != facts.name) config.microvm.vms));
        message = "kanbei-vm: no other guest may pass through the same PCI functions";
      }
      {
        assertion =
          config.systemd.services."kanbei-vm-prep".restartIfChanged == false
          && config.systemd.services."kanbei-swtpm".restartIfChanged == false
          && config.microvm.vms.${facts.name}.restartIfChanged == false;
        message = "kanbei-vm: prep/swtpm/VM must not restart on a host switch";
      }
      {
        # Ticket #584: the Kanbei units are excluded from the host's alert template on purpose.
        assertion = lib.all (
          s: !lib.any (dep: lib.hasPrefix "cloudflare-email@" dep) (s.onFailure or [ ])
        ) (lib.attrValues (lib.filterAttrs (n: _: lib.hasPrefix "kanbei" n) config.systemd.services));
        message = "kanbei-vm: kanbei units must not depend on the host's cloudflare-email@ template";
      }
      {
        assertion = lib.all (b: !lib.any (p: lib.hasPrefix swtpmDir p) b.paths) (
          lib.attrValues config.services.restic.backups
        );
        message = "kanbei-vm: the swtpm state must never enter a restic snapshot";
      }
    ];

    warnings = [
      "kanbeiVm.enable stops nvidia.nix, llm.nix and photo-triage.nix on this host and passes the 3090 to the kanbei guest; the guest only uses it after the fast-boot cutover in docs/kanbei-vm.md"
    ];
  };
}
