# The `kanbei` guest (smores56/sdlc#584, part of #509): the private-data VM. qemu, no NIC, the
# RTX 3090 passed through by VFIO, and a LUKS2 data volume sealed to a per-VM software TPM whose
# state stays on the host. This module owns both sides: the guest NixOS config and the host
# plumbing (VFIO binding, swtpm, console, backup).
#
# Everything is behind `kanbeiVm.enable` (default false). Until the one-time cutover in
# docs/kanbei-vm.md the host still runs Immich and llama-cpp on the 3090, so enabling is
# a deliberate operator action; with it enabled the nvidia/llm modules go inert
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

  # Shared guest-agent facts: the trusted kernel uid and the payload uid.
  agentFacts = import ../lib/kanbei-agent.nix;

  inherit (facts) stateDir vmStateDir;
  # Root-only: swtpm NVRAM is the seal for the guest disk.
  swtpmDir = "${stateDir}/swtpm";
  # qemu runs as `microvm:kvm`, so the socket directory is group-traversable but not world.
  # QEMU's TPM emulator backend speaks the swtpm protocol (control commands and TPM traffic)
  # on the --ctrl channel only; a separate data socket is never used.
  runDir = "/run/kanbei-vm";
  swtpmCtrl = "${runDir}/swtpm.ctrl";
  # systemd opens these as root before dropping to `microvm`; the parent is 0700 root.
  consoleDir = "${stateDir}/console";
  consoleFile = "${consoleDir}/console.log";
  secretDir = "${stateDir}/secrets";
  # The guest writes the first-boot recovery key here before it formats the volume; root-only,
  # never part of a backup.
  enrollDir = "${stateDir}/enroll";
  # The ingest writer drops age-encrypted batches here; T14 owns the path, this share reads it.
  inboxDir = (import ../lib/ingest-vm.nix { inherit lib; }).constants.inboxDir;
  # Shared by every host listener the guest dials (chat relay, ACME responder, age-recipient
  # and search relay) and read by the guest from its read-only `kanbei-secrets` share. It is
  # generated here, root-only, so no sops key is needed and no unauthenticated channel exists.
  relayTokenFile = "${secretDir}/relay-token";

  # The phone's receive-encrypted Syncthing folder and the password contract, both owned
  # by the host side of the pipeline (`docs/kanbei-phone.md`).
  phone = import ../lib/phone-pipeline.nix;
  phoneTranslation = [
    # Guest root is the decrypt user. On this share only, map it to `vault` so the
    # ciphertext (0700 vault) is readable; the share is read-only, so root gains no write.
    "--translate-uid=guest:0:${toString vaultId}:1"
    "--translate-gid=guest:0:${toString vaultId}:1"
    "--modcaps=-mknod"
  ];

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
  # the host instead of host root. The trusted agent kernel has its own uid (`agentFacts`) and
  # maps there too; guest root keeps mapping to `nobody`.
  guestUid = 1000;
  vaultId = config.users.users.vault.uid;
  dataTranslation = [
    "--translate-uid=guest:0:65534:1"
    "--translate-uid=guest:${toString guestUid}:${toString vaultId}:1"
    "--translate-uid=guest:${toString agentFacts.coreUid}:${toString vaultId}:1"
    "--translate-gid=guest:0:65534:1"
    "--translate-gid=guest:${toString guestUid}:${toString vaultId}:1"
    "--translate-gid=guest:${toString agentFacts.coreUid}:${toString vaultId}:1"
    # `guest:` only maps request credentials; without the `host:` direction the guest sees
    # the host owner (vault) and the agent, running as its own uid, cannot read the tree.
    "--translate-uid=host:${toString vaultId}:${toString agentFacts.coreUid}:1"
    "--translate-gid=host:${toString vaultId}:${toString agentFacts.coreUid}:1"
    "--modcaps=-mknod"
  ];
  # The inbox batches are 0600 root and the tree is 0750 root. Only the trusted kernel uid is
  # mapped to host root on this read-only share; guest root maps to `nobody`, and the payload
  # uid 1000 keeps its own identity (and so cannot read a batch).
  inboxTranslation = [
    "--translate-uid=guest:0:65534:1"
    "--translate-uid=guest:${toString agentFacts.coreUid}:0:1"
    "--translate-gid=guest:0:65534:1"
    "--translate-gid=guest:${toString agentFacts.coreUid}:0:1"
    # Presentation: the guest sees root-owned batch files as the kernel uid, which is the
    # only reader on this share.
    "--translate-uid=host:0:${toString agentFacts.coreUid}:1"
    "--translate-gid=host:0:${toString agentFacts.coreUid}:1"
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

  phoneShare = {
    inherit (phone) tag;
    source = phone.hostFolder;
    mountPoint = phone.guestMount;
    proto = "virtiofs";
    readOnly = true;
    posixAcl = false;
    extraArgs = phoneTranslation;
  };

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
  # The mapping is opened here, not from /etc/crypttab: the credential and escrow live on
  # virtiofs shares that systemd mounts after local-fs.target, so an early crypttab unlock
  # (and anything ordered before it) can never see them on first boot.
  guestInit = pkgs.writeShellScript "kanbei-data-open" ''
    set -euo pipefail
    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.cryptsetup
        pkgs.e2fsprogs
        pkgs.systemd
        pkgs.tpm2-tools
        pkgs.util-linux
      ]
    }
    dev=${dataDevice}
    key=/run/kanbei-recovery.key
    escrow=/mnt/kanbei-enroll/recovery.key
    contract=/run/kanbei-secrets/kanbei-recovery-key
    # The guest journal is volatile, so the serial console is the only trace a failed
    # first boot leaves on the host. Say every decision and never wait on input.
    say() { echo "kanbei-data-open: $*" > /dev/console; }
    tpm=/dev/tpm0
    [ -e "$tpm" ] || tpm=auto

    for _ in $(seq 1 120); do
      [ -e "$dev" ] && break
      sleep 0.5
    done
    [ -e "$dev" ] || { say "$dev did not appear"; exit 1; }
    say "tpm devices: $(ls /dev/tpm* 2>/dev/null | tr '\n' ' ')"
    say "tpm2-setup: $(systemctl show -p ActiveState -p Result systemd-tpm2-setup.service 2>/dev/null | tr '\n' ' ')"
    # Independent of LUKS: prove the emulated TPM answers before blaming the enrollment.
    for node in /dev/tpmrm0 /dev/tpm0; do
      [ -e "$node" ] || continue
      set +e
      timeout 20 tpm2_getrandom -T "device:$node" --hex 8 >/tmp/kanbei-tpm.out 2>&1
      tpmrc=$?
      set -e
      say "tpm smoke $node: exit $tpmrc $(head -c 200 /tmp/kanbei-tpm.out | tr '\n' ' ')"
    done

    enroll_token() {
      say "enrolling the TPM2 token from $1 (device $tpm)"
      set +e
      timeout 150 systemd-cryptenroll --tpm2-device="$tpm" \
        --unlock-key-file="$1" "$dev" </dev/null >/dev/console 2>&1
      rc=$?
      set -e
      [ "$rc" -eq 0 ] || { say "TPM enrollment failed or timed out (exit $rc)"; exit 1; }
      say "TPM token enrolled"
    }

    if cryptsetup isLuks "$dev"; then
      say "$dev already holds LUKS"
      # cryptsetup(8) has no --tpm2-device option; the token handler lives in
      # systemd-cryptsetup, which is what a crypttab entry would have used.
      if systemd-cryptsetup attach kanbei-data "$dev" - tpm2-device=auto 2>/dev/null; then
        say "opened with the TPM token"
      else
        [ -r "$escrow" ] || { say "no token works and no escrowed key exists"; exit 1; }
        enroll_token "$escrow"
        systemd-cryptsetup attach kanbei-data "$dev" - tpm2-device=auto \
          || cryptsetup open --key-file "$escrow" "$dev" kanbei-data
        say "opened after enrolling the token"
      fi
    else
      umask 077
      if [ -r "$contract" ]; then
        say "using the sops recovery-key contract"
        install -m 0400 "$contract" "$key"
      elif [ -r "$escrow" ]; then
        say "reusing the escrowed recovery key"
        install -m 0400 "$escrow" "$key"
      else
        say "generating a recovery key and escrowing it before the format"
        head -c 64 /dev/urandom > "$key"
        install -m 0600 "$key" "$escrow"
      fi
      say "formatting LUKS2"
      cryptsetup luksFormat --type luks2 --batch-mode --label KANBEI --key-file "$key" "$dev"
      enroll_token "$key"
      say "opening the new mapping"
      cryptsetup open --key-file "$key" "$dev" kanbei-data
    fi

    if [ "$(blkid -o value -s TYPE /dev/mapper/kanbei-data 2>/dev/null)" != "ext4" ]; then
      say "making the ext4 filesystem"
      mkfs.ext4 -q -L kanbei-data -m 1 /dev/mapper/kanbei-data
    fi
    say "volume ready"
  '';

  # Both restic jobs snapshot the same image. The helper refcounts jobs under a flock so the
  # guest stops for the first job and starts only after the last cleanup (`freeze.py`).
  freezeTool = pkgs.writeShellApplication {
    name = "kanbei-freeze";
    runtimeInputs = [ pkgs.python3 ];
    text = ''
      # State lives in the durable host state directory, not /run/kanbei-vm: RESTIC stops
      # swtpm, whose RuntimeDirectory disappears with its unit, and the refcount must
      # survive that stop for the cleanup half to read it.
      exec ${pkgs.python3}/bin/python3 ${../lib/kanbei/freeze.py} \
        --run-dir ${stateDir}/backup --systemctl ${config.systemd.package}/bin/systemctl "$@"
    '';
  };
  freezeHook = job: action: "${freezeTool}/bin/kanbei-freeze --job ${job} --${action}";

  # Runtime half of the "clean IOMMU group" check: evaluation only sees the recorded facts.
  # writeShellScriptBin: environment.systemPackages needs a directory to merge.
  verifyScript = pkgs.writeShellScriptBin "kanbei-vm-verify" ''
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
    for p in ${swtpmDir} ${consoleDir} ${secretDir}; do
      if [ "$(${pkgs.coreutils}/bin/stat -c %a "$p")" != "700" ]; then
        echo "FAIL: $p is not 0700" >&2
        fail=1
      fi
    done
    if [ "$(${pkgs.coreutils}/bin/stat -c %a:%U:%G ${relayTokenFile})" != "400:root:root" ]; then
      echo "FAIL: ${relayTokenFile} is not 0400 root:root; every relay authenticates with it" >&2
      fail=1
    fi
    if [ ! -S ${swtpmCtrl} ]; then
      echo "FAIL: ${swtpmCtrl} is missing" >&2
      fail=1
    fi
    if [ ! -c /dev/vhost-vsock ]; then
      echo "FAIL: /dev/vhost-vsock is missing; vhost_vsock is not loaded" >&2
      fail=1
    elif [ "$(${pkgs.coreutils}/bin/stat -c %a:%U:%G /dev/vhost-vsock)" != "660:root:kvm" ]; then
      # The vsock control surface is root:kvm only; the chat relay has no device access.
      echo "FAIL: /dev/vhost-vsock is $(${pkgs.coreutils}/bin/stat -c %a:%U:%G /dev/vhost-vsock), expected 660:root:kvm" >&2
      fail=1
    fi
    exit "$fail"
  '';

  # The guest submodule is evaluated by microvm.nix in its own module system, which does not
  # inherit the host's specialArgs; hand the input package over as a module argument.
  kanbeiInput = inputs.kanbei.packages.${pkgs.stdenv.hostPlatform.system}.default;

  guest =
    { lib, ... }:
    {
      _module.args.kanbeiInput = kanbeiInput;
      # T11: the llama.cpp chat/embeddings/rerank lanes. A guest module, so it only evaluates
      # while this guest exists (kanbeiVm.enable).
      imports = [
        ./kanbei-inference.nix
        ./kanbei-guest-access.nix
        ./kanbei-phone.nix
        ./kanbei-agent.nix
        ./kanbei-nanobot.nix
      ];

      microvm = {
        hypervisor = "qemu";
        vcpu = 8;
        # Weights are GPU-resident; the guest only holds the (reduced) prompt cache, the CPU
        # embedding/rerank lanes and userspace.
        mem = 6144;
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
            posixAcl = false;
            extraArgs = inboxTranslation;
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
        ++ vaultShares
        ++ [ phoneShare ];
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
            [ -S ${swtpmCtrl} ] && break
            ${pkgs.coreutils}/bin/sleep 0.2
            i=$((i + 1))
          done
          if [ ! -S ${swtpmCtrl} ]; then
            echo "kanbei: ${swtpmCtrl} is missing; refusing to boot without the vTPM" >&2
            exit 1
          fi
        '';
        # The qemu `microvm` machine emits XSDT/FACP/DSDT/APIC only: no TPM2 ACPI table, so
        # the guest kernel never binds tpm_crb and /dev/tpm0 does not exist (verified by
        # booting this kernel on both machines). q35 emits the TPM2 table and the same
        # `tpm-crb` device works, so the seal needs a machine with real ACPI.
        qemu.machine = "q35";
        # microvm.nix has no vTPM option: the host unit owns swtpm and this connects QEMU to
        # its --ctrl socket, the one channel the emulator backend uses. Pointing it at a
        # --server data socket makes QEMU block in its first read before any CPU starts.
        # `-monitor none` keeps the guest from ever reaching the QEMU monitor.
        qemu.extraArgs = [
          "-chardev"
          "socket,id=chrtpm,path=${swtpmCtrl}"
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

      # The volume is opened by kanbei-data-open.service, not from /etc/crypttab: a crypttab
      # entry is ordered before local-fs.target, but the recovery material lives on virtiofs
      # shares that are mounted later, so the first boot deadlocks. The mount is declared
      # here rather than in `fileSystems` for the same reason: a .mount unit is implicitly
      # ordered before local-fs.target, which would order it before the service that
      # creates its device.
      systemd.mounts = [
        {
          what = "/dev/mapper/kanbei-data";
          where = "/var/lib/kanbei";
          type = "ext4";
          options = "nodev,nosuid,noatime";
          wantedBy = [ "multi-user.target" ];
          unitConfig.DefaultDependencies = false;
          conflicts = [ "umount.target" ];
          before = [
            "umount.target"
            "kanbei.service"
          ];
          after = [
            "local-fs.target"
            "kanbei-data-open.service"
          ];
          requires = [ "kanbei-data-open.service" ];
        }
      ];

      # 0750 root:kanbei: guest uid 1000 (kanbei) must traverse the LUKS mount; secrets stay
      # 0700 root inside it.
      systemd.tmpfiles.rules = [
        "d /var/lib/kanbei 0750 root kanbei -"
        "d /run/kanbei-secrets 0755 root root -"
      ];

      systemd.services.kanbei-data-open = {
        description = "Open the kanbei data volume (first boot: format, enroll, mkfs)";
        wantedBy = [ "multi-user.target" ];
        # Both are virtiofs shares that systemd mounts after local-fs.target; this unit is
        # an ordinary late service, so waiting for them cannot cycle.
        unitConfig.RequiresMountsFor = [
          "/mnt/kanbei-enroll"
          "/run/kanbei-secrets"
        ];
        after = [ "systemd-udevd.service" ];
        restartIfChanged = false;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          UMask = "0077";
          ExecStart = guestInit;
        };
      };

      # The guest journal is volatile and there is no login on that root, so a failed unit
      # leaves nothing behind. Dump the failure summary to the serial console, which the host
      # keeps at /var/lib/kanbei-vm/console/console.log (root-only).
      systemd.services.kanbei-boot-report = {
        description = "Report failing kanbei units on the serial console";
        wantedBy = [ "multi-user.target" ];
        after = [
          "kanbei-age-identity.service"
          "kanbei-cert.service"
          "kanbei-ui.service"
          "kanbei-nanobot.service"
          "kanbei.service"
        ];
        restartIfChanged = false;
        serviceConfig = {
          Type = "oneshot";
        };
        script = ''
          sleep 20
          {
            ${pkgs.systemd}/bin/systemctl --failed --no-pager
            ${pkgs.coreutils}/bin/id kanbei-core || true
            ${pkgs.coreutils}/bin/stat -c '%a %u:%g %n' \
              /mnt/kanbei/inbox /mnt/kanbei/vault /mnt/kanbei/todo \
              /var/lib/kanbei /var/lib/kanbei/agent /run/kanbei-secrets 2>&1 || true
            ${pkgs.systemd}/bin/journalctl -b --no-pager -n 120 \
              -u kanbei-data-open.service -u kanbei-age-identity.service \
              -u kanbei-age-publish.service -u kanbei-cert.service \
              -u kanbei-ui.service -u kanbei-nanobot.service \
              -u kanbei-nanobot-probe.service -u kanbei.service
          } > /dev/console 2>&1 || true
        '';
      };

      system.stateVersion = "26.05";
    };
in
{
  imports = [
    inputs.microvm.nixosModules.host
    ./kanbei-access.nix
  ];

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
      "d ${stateDir} 0750 root root -"
      "d ${swtpmDir} 0700 root root -"
      "d ${consoleDir} 0700 root root -"
      "d ${secretDir} 0700 root root -"
      "d ${enrollDir} 0700 root root -"
      "d ${inboxDir} 0750 root root -"
    ];

    # Upstream udev leaves /dev/vhost-vsock 0666. QEMU only needs the device as microvm:kvm, so
    # the rule narrows it to 0660 root:kvm; kanbei-vm-verify asserts the result.
    services.udev.extraRules = ''
      KERNEL=="vhost-vsock", GROUP="kvm", MODE="0660"
    '';

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
      # virtiofsd must serve the mounted todo tree, not the plain directory the
      # size-capped image hides when it is not mounted.
      unitConfig.RequiresMountsFor = [ "/var/lib/data/todo" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail
        install -d -m 0750 -o root -g root ${stateDir}
        install -d -m 0700 -o root -g root ${swtpmDir} ${consoleDir} ${secretDir} ${enrollDir} ${stateDir}/backup
        install -d -m 0750 -o root -g root ${inboxDir}
        install -d -m 0700 -o microvm -g kvm ${vmStateDir}
        # sops contract: the operator's own recovery credential, not the generated one.
        if [ -r ${recoveryKeyFile} ]; then
          install -m 0400 -o root -g root ${recoveryKeyFile} ${secretDir}/kanbei-recovery-key
        fi
        # Shared relay token: every host listener and the guest read this one file.
        if [ ! -s ${relayTokenFile} ]; then
          umask 077
          ${pkgs.openssl}/bin/openssl rand -hex 32 > ${relayTokenFile}
        fi
        ${pkgs.coreutils}/bin/chmod 0400 ${relayTokenFile}
        ${pkgs.coreutils}/bin/chown root:root ${relayTokenFile}
        # A modules-load restart (every switch) recreates the vsock device with upstream's
        # 0666; the udev rule only covers coldplug. Load it here and re-assert the narrowing
        # before qemu opens it, so the relay never gains the device.
        ${pkgs.kmod}/bin/modprobe -q vhost_vsock || true
        if [ -c /dev/vhost-vsock ]; then
          ${pkgs.coreutils}/bin/chgrp kvm /dev/vhost-vsock
          ${pkgs.coreutils}/bin/chmod 0660 /dev/vhost-vsock
        fi
      '';
    };

    # The phone folder password reaches the guest as a read-only file on the
    # `kanbei-secrets` share. Its own unit (not kanbei-vm-prep, which is PartOf the VM) so
    # a sops rotation only re-stages the file; the guest's decrypt timer copies it into
    # the LUKS volume on its next run.
    systemd.services.kanbei-phone-password = {
      description = "Stage the phone folder password into the kanbei guest's secret share";
      wantedBy = [ "multi-user.target" ];
      before = [ "microvm-virtiofsd@${facts.name}.service" ];
      after = [ "kanbei-vm-prep.service" ];
      requires = [ "kanbei-vm-prep.service" ];
      restartIfChanged = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        UMask = "0077";
      };
      script = ''
        set -euo pipefail
        if [ -r ${phone.passwordContract} ]; then
          install -m 0400 -o root -g root ${phone.passwordContract} ${secretDir}/phone-folder-password
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
        ExecStart = "${pkgs.swtpm}/bin/swtpm socket --tpm2 --tpmstate dir=${swtpmDir} --ctrl type=unixio,path=${swtpmCtrl},mode=0660";
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
      # The instance unit is generated by microvm.nix; without asDropin this declaration
      # replaces it (and drops its ExecStart).
      overrideStrategy = "asDropin";
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
        # writeShellScriptBin is a directory; the unit needs the file inside it.
        ExecStart = "${verifyScript}/bin/kanbei-vm-verify";
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
        backupPrepareCommand = freezeHook "kanbei-r2" "prepare";
        backupCleanupCommand = freezeHook "kanbei-r2" "cleanup";
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
        backupPrepareCommand = freezeHook "kanbei-local" "prepare";
        backupCleanupCommand = freezeHook "kanbei-local" "cleanup";
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
        message = "kanbei-vm: the enabled host must not load nvidia or run llama-cpp; nvidia.nix/llm.nix must stay inert while the guest owns the GPU";
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
      {
        # Evaluated guest config, not the let-binding: the share the guest actually mounts must
        # be the read-only phone-untrusted tree.
        assertion =
          let
            shares = config.microvm.vms.${facts.name}.config.config.microvm.shares;
            share = lib.findFirst (s: s.tag == phone.tag) null shares;
          in
          share != null
          && share.readOnly == true
          && share.source == phone.hostFolder
          && share.mountPoint == phone.guestMount;
        message = "kanbei-vm: the phone-untrusted share must be read-only at ${phone.guestMount}";
      }
      {
        # The relay token lives on the root-only secret share and nowhere else; every host
        # listener loads it as a systemd credential.
        assertion =
          lib.hasPrefix "${secretDir}/" relayTokenFile
          && lib.elem "d ${secretDir} 0700 root root -" config.systemd.tmpfiles.rules;
        message = "kanbei-vm: the relay token must live in the root-only secret directory";
      }
      {
        # microvm.nix generates microvm@<name>.service; a plain declaration would replace it.
        assertion = config.systemd.services."microvm@${facts.name}".overrideStrategy == "asDropin";
        message = "kanbei-vm: the microvm@${facts.name} override must be an asDropin";
      }
      {
        # Guest uid 1000 must traverse the LUKS mount; secrets inside it stay root-only.
        assertion =
          lib.elem "d /var/lib/kanbei 0750 root kanbei -"
            config.microvm.vms.${facts.name}.config.config.systemd.tmpfiles.rules;
        message = "kanbei-vm: /var/lib/kanbei must be 0750 root:kanbei for the guest payload user";
      }
      {
        # The freeze hook is shared by both jobs and keyed by job, so neither can start the
        # guest while the other still snapshots (freeze.py refcount).
        assertion =
          let
            jobs = [
              config.services.restic.backups.kanbei-r2
              config.services.restic.backups.kanbei-local
            ];
            hooks = map (b: toString b.backupPrepareCommand) jobs;
          in
          lib.all (h: lib.hasInfix "--prepare" h && lib.hasInfix "--job kanbei-" h) hooks
          && lib.all (b: !(lib.hasInfix "backup-was-active" (toString b.backupPrepareCommand))) jobs;
        message = "kanbei-vm: both restic jobs must use the refcounted kanbei-freeze helper";
      }
      {
        # The decrypted tree lives only inside the guest's LUKS image; no host restic job
        # may name it (the image is what restic backs up, as ciphertext).
        assertion = lib.all (b: !lib.any (p: lib.hasPrefix "/var/lib/kanbei/phone" p) b.paths) (
          lib.attrValues config.services.restic.backups
        );
        message = "kanbei-vm: the decrypted phone tree must never enter a host restic snapshot";
      }
      {
        # The ciphertext copy is under /var/lib/data, which the host jobs already cover.
        assertion = lib.any (b: lib.any (p: lib.hasPrefix "/var/lib/data" p) b.paths) (
          lib.attrValues config.services.restic.backups
        );
        message = "kanbei-vm: the phone ciphertext folder must be covered by a restic job (ciphertext backup is intended)";
      }
    ];

    warnings = [
      "kanbeiVm.enable stops nvidia.nix and llm.nix on this host and passes the 3090 to the kanbei guest; the guest only uses it after the fast-boot cutover in docs/kanbei-vm.md"
    ];
  };
}
