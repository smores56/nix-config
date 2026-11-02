# The local backup disk: the encrypted target for the local restic repo
# (modules/nixos/restic-backup.nix writes /var/backup/restic). This module owns
# only the mount.
# Mounted with `nofail` so a missing/failed disk never blocks boot — the local
# restic unit declares `RequiresMountsFor`, so it fails loudly instead.
# With `luks.enable` the filesystem sits on /dev/mapper/<name>, opened at boot
# from /etc/crypttab by a keyfile on the encrypted root (passphrase slot as the
# recovery path), so the disk is never readable off the machine.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.backup;
in
{
  options.backup = lib.mkOption {
    type = lib.types.submodule {
      options = {
        enable = lib.mkEnableOption "the local backup disk";
        mountPoint = lib.mkOption {
          type = lib.types.path;
          default = "/var/backup";
          description = "Where the backup disk is mounted; the local restic repo lives at <mountPoint>/restic.";
        };
        device = lib.mkOption {
          type = lib.types.str;
          default = "/dev/disk/by-label/backup";
          description = "Block device or by-label/by-uuid path of the backup disk.";
        };
        luks = {
          enable = lib.mkEnableOption "encrypting the backup disk with LUKS (keyfile unlock, plus an offline passphrase slot)";
          device = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "/dev/disk/by-id/ata-WDC_WD50EZRX-00MVLB1_WMC3H0D5XKSY";
            description = "The encrypted partition to open at boot: a stable by-id path, never a kernel name like /dev/sda1.";
          };
          name = lib.mkOption {
            type = lib.types.str;
            default = "backup";
            description = "mapper name; the filesystem lives on /dev/mapper/<name>, which `device` defaults to when this is enabled.";
          };
          keyFile = lib.mkOption {
            type = lib.types.str;
            default = "/etc/luks/backup.key";
            description = "Root-only keyfile created by the operator (mode 0400). It lives on the encrypted root, so the disk still opens unattended; the LUKS passphrase slot is the recovery path if the root is lost.";
          };
        };
      };
    };
    default = { };
    description = "The local encrypted backup disk; the local restic repo lives beneath it.";
  };

  config = lib.mkIf cfg.enable {
    # The encrypted disk is opened by systemd-cryptsetup from /etc/crypttab (a
    # keyfile on the encrypted root, so boot stays unattended). `nofail` keeps a
    # missing disk or keyfile from blocking boot: the units declare
    # RequiresMountsFor, so they fail loudly instead.
    # The entry must not exist at all unless LUKS is on: declaring
    # `environment.etc.crypttab.text` under a false condition still creates the
    # file entry, which then has neither `text` nor `source` and fails the build.
    environment.etc = lib.mkIf (cfg.luks.enable && cfg.luks.device != null) {
      crypttab.text = "${cfg.luks.name} ${cfg.luks.device} ${cfg.luks.keyFile} luks,nofail\n";
    };
    environment.systemPackages = lib.optional cfg.luks.enable pkgs.cryptsetup;

    fileSystems.${cfg.mountPoint} = {
      inherit (cfg) device;
      fsType = "ext4";
      options = [
        "noatime"
        "nofail"
        "x-systemd.device-timeout=10"
      ];
    };

    assertions = [
      {
        assertion = !cfg.luks.enable || cfg.luks.device != null;
        message = "backup.luks.enable needs backup.luks.device (the by-id path of the encrypted partition).";
      }
      {
        assertion = !cfg.luks.enable || lib.hasPrefix "/dev/mapper/${cfg.luks.name}" cfg.device;
        message = "backup.device must stay on /dev/mapper/${cfg.luks.name} while backup.luks is enabled; the filesystem lives inside the mapping.";
      }
      {
        assertion = !cfg.luks.enable || lib.hasPrefix "/" cfg.luks.keyFile;
        message = "backup.luks.keyFile must be an absolute path on the root filesystem.";
      }
    ];
  };
}
