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

  # The local restic repo lives at <mountPoint>/restic (restic-backup.nix).
  mountPoint = "/var/backup";
  # mapper name; the filesystem lives on /dev/mapper/<name>.
  luksName = "backup";
  # Root-only keyfile created by the operator (mode 0400). It lives on the
  # encrypted root, so the disk still opens unattended; the LUKS passphrase slot
  # is the recovery path if the root is lost.
  luksKeyFile = "/etc/luks/backup.key";
in
{
  options.backup = lib.mkOption {
    type = lib.types.submodule {
      options = {
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
        };
      };
    };
    default = { };
    description = "The local encrypted backup disk; the local restic repo lives beneath it.";
  };

  config = {
    # The encrypted disk is opened by systemd-cryptsetup from /etc/crypttab (a
    # keyfile on the encrypted root, so boot stays unattended). `nofail` keeps a
    # missing disk or keyfile from blocking boot: the units declare
    # RequiresMountsFor, so they fail loudly instead.
    # The entry must not exist at all unless LUKS is on: declaring
    # `environment.etc.crypttab.text` under a false condition still creates the
    # file entry, which then has neither `text` nor `source` and fails the build.
    environment.etc = lib.mkIf (cfg.luks.enable && cfg.luks.device != null) {
      crypttab.text = "${luksName} ${cfg.luks.device} ${luksKeyFile} luks,nofail\n";
    };
    environment.systemPackages = lib.optional cfg.luks.enable pkgs.cryptsetup;

    fileSystems.${mountPoint} = {
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
        assertion = !cfg.luks.enable || lib.hasPrefix "/dev/mapper/${luksName}" cfg.device;
        message = "backup.device must stay on /dev/mapper/${luksName} while backup.luks is enabled; the filesystem lives inside the mapping.";
      }
    ];
  };
}
