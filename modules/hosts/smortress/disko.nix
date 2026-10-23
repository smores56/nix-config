# Declarative disk layout for smortress (see AGENTS.md). disko owns `/` and
# `/boot` — it derives `fileSystems` from here — so hardware.nix omits them.
#
# The 970 EVO is the encrypted main disk for the LUKS migration; the 980 PRO
# stays as the rollback until the new system has booted twice. Do **not**
# `nixos-rebuild switch` this config on the old (980 PRO) system: it declares
# `/` on `/dev/mapper/cryptroot`, which does not exist there. Run disko and
# nixos-install from the migration worktree instead.
#
# The backup HDD (sda, mounted at /var/backup by modules/nixos/backup.nix) is
# left untouched.
{
  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/disk/by-id/nvme-Samsung_SSD_970_EVO_1TB_S5H9NS0NA57329Z";
    content = {
      type = "gpt";
      partitions = {
        boot = {
          size = "1G";
          type = "EF00";
          label = "EFI";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [
              "fmask=0077"
              "dmask=0077"
            ];
          };
        };
        root = {
          size = "100%";
          label = "root";
          content = {
            type = "luks";
            name = "cryptroot";
            # Disko prompts for the LUKS passphrase twice when neither a
            # passwordFile nor a keyFile is set. Store the passphrase offline.
            settings = {
              allowDiscards = true;
              fallbackToPassword = true;
              # Enroll the TPM after the first boot with
              # systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7.
              crypttabExtraOpts = [ "tpm2-device=auto" ];
            };
            # Generate a recovery key after install with
            # systemd-cryptenroll --recovery-key; store it offline.
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
            };
          };
        };
      };
    };
  };
}
