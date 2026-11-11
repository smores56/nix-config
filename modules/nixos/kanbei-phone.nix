# Phone pipeline, guest half (smores56/sdlc#593, part of #509): decrypt the phone's
# receive-encrypted Syncthing folder into the LUKS volume and hand Kanbei a manifest plus a
# contract-shaped batch.
#
# Imported by the guest config in `modules/nixos/kanbei-vm.nix`, so it only evaluates while
# `kanbeiVm.enable` is set. The host stores ciphertext only; the password enters through the
# read-only `/run/kanbei-secrets` share (`/run/secrets/phone-folder-password` on the host)
# and is staged into the LUKS volume at 0400. Paths and naming come from
# `modules/lib/phone-pipeline.nix`.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  phone = import ../lib/phone-pipeline.nix;
  python = "${pkgs.python3}/bin/python3";
  patterns = pkgs.writeText "phone-export-patterns.json" (builtins.toJSON phone.patterns);

  inherit (phone) stateDir;
  batchDir = "${stateDir}/batches";
in
{
  systemd.tmpfiles.rules = [
    # The password and the dedupe index are root-only. The decrypted tree is for the
    # guest's payload user; its parent is root-only, so the share into Kanbei's control
    # plane is a T24 wiring detail.
    "d ${phone.plaintextDir} 0750 root kanbei -"
    "d ${stateDir} 0700 root root -"
    "d ${stateDir}/secrets 0700 root root -"
    "d ${batchDir} 0750 root kanbei -"
    "d /run/kanbei-secrets 0755 root root -"
  ];

  systemd.services.syncthing-decrypt = {
    description = "Decrypt the phone's receive-encrypted Syncthing folder into the kanbei volume";
    wantedBy = [ ];
    unitConfig = {
      RequiresMountsFor = [
        "/var/lib/kanbei"
        phone.guestMount
      ];
      # A missing password or a wrong folder type is a retryable condition: the timer
      # re-runs every hour, so a rate limit only bounds the noise in the journal.
      StartLimitIntervalSec = "1h";
      StartLimitBurst = 3;
    };
    after = [ "local-fs.target" ];
    restartIfChanged = false;
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Group = "root";
      UMask = "0027";
      ExecStart = "${python} ${../lib/phone/phone_decrypt.py} --source ${phone.guestMount} --to ${phone.plaintextDir} --contract ${phone.guestContract} --staged ${phone.stagedPassword} --state ${stateDir}/index.json --batch-dir ${batchDir} --heartbeat ${stateDir}/heartbeat.json --manifest ${phone.manifestName} --max-file-bytes ${toString phone.maxFileBytes} --syncthing ${pkgs.syncthing}/bin/syncthing --patterns ${patterns}";
      # The LUKS volume is the only writable path; the work and staging trees live there
      # so the final swap is a same-filesystem rename.
      ReadWritePaths = [ "/var/lib/kanbei" ];
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateDevices = true;
      NoNewPrivileges = true;
      CapabilityBoundingSet = "";
      AmbientCapabilities = "";
      LockPersonality = true;
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictAddressFamilies = [ "AF_UNIX" ];
      SystemCallArchitectures = "native";
      SystemCallFilter = "@system-service";
      # `syncthing decrypt` is a Go binary; a private /tmp would put the work tree on
      # tmpfs and break the atomic directory exchange across filesystems.
      PrivateTmp = false;
    };
  };

  systemd.timers.syncthing-decrypt = {
    description = "Hourly decrypt of the phone's Syncthing folder";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnCalendar = "hourly";
      RandomizedDelaySec = "2min";
      Persistent = true;
      Unit = "syncthing-decrypt.service";
    };
  };

  assertions = [
    {
      assertion = phone.maxFileBytes > 0;
      message = "kanbei-phone: the per-file size cap must be positive";
    }
    {
      assertion = phone.plaintextDir == "/var/lib/kanbei/phone";
      message = "kanbei-phone: the decrypted tree must stay at /var/lib/kanbei/phone (the documented path contract)";
    }
    {
      assertion = phone.stagedPassword == "/var/lib/kanbei/secrets/phone-folder-password";
      message = "kanbei-phone: the staged password must stay inside the LUKS volume";
    }
    {
      # The phone folder is the only host path the guest reads for this pipeline, and it
      # must never be writable from inside the guest.
      assertion =
        let
          share = lib.findFirst (s: s.tag == phone.tag) null (config.microvm.shares or [ ]);
        in
        share != null && share.readOnly == true && share.mountPoint == phone.guestMount;
      message = "kanbei-phone: the phone-untrusted virtiofs share must exist, mount at ${phone.guestMount} and be read-only";
    }
  ];
}
