# Mount for the encrypted local restic disk; restic-backup.nix writes
# /var/backup/restic. `nofail` keeps a missing disk from blocking boot; the restic
# unit's RequiresMountsFor then fails loudly. With luks.enable, crypttab opens it
# with a keyfile on the encrypted root.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.backup;

  mountPoint = "/var/backup";
  # mapper name; the filesystem lives on /dev/mapper/<name>.
  luksName = "backup";
  # Root-only (0400). On the encrypted root, so the disk opens unattended; the LUKS
  # passphrase slot is the recovery path.
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
    # The entry must not exist unless LUKS is on: `environment.etc.crypttab.text` under a
    # false condition still creates a file entry with neither `text` nor `source`.
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
