# The 970 EVO: the rollback system plus, until `retire_old`, the primary restic
# repository (homelab-platform#680). Every partlabel carries a distinct name
# because the 980 boots the same machine with `EFI`/`root`; duplicate partlabels
# would make `/dev/disk/by-partlabel` ambiguous while both disks are installed.
#
# `passwordFile` is the installer's copy of the recovery passphrase, delivered
# with `nixos-anywhere --disk-encryption-keys`; unlike `settings.keyFile` it is
# not written into the installed initrd, so both volumes prompt at boot.
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
          label = "EFI-rollback";
          priority = 1;
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
          size = "679G";
          label = "rollback-root";
          content = {
            type = "luks";
            name = "rollback-root";
            passwordFile = "/tmp/rollback-pass";
            settings = {
              # Accepted trade: discard leaks which blocks are in use, not their contents.
              allowDiscards = true;
            };
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
            };
          };
        };
        # Sized for the projected 170-200G repository with churn room; it grows to
        # the whole disk when the rollback partition is retired. Formatted but not
        # mounted here: this system's own restic repository stays on the HDD, and a
        # rescue boot must never wait on (or be blocked by) an empty volume. Open it
        # by hand for a restore; the Ubuntu host mounts it as its primary.
        primary = {
          size = "250G";
          label = "rollback-primary";
          content = {
            type = "luks";
            name = "backup-primary";
            passwordFile = "/tmp/rollback-pass";
            settings = {
              allowDiscards = true;
            };
            initrdUnlock = false;
            content = {
              type = "filesystem";
              format = "ext4";
            };
          };
        };
      };
    };
  };
}
