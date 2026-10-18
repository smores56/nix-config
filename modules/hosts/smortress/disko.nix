# Declarative disk layout for smortress (see AGENTS.md). disko owns `/` and
# `/boot` — it derives `fileSystems` from here — so hardware.nix omits them.
#
# The partition labels are pinned to `EFI`/`root` (disko's default would be
# `disk-main-boot`/`disk-main-root`) so the derived `/dev/disk/by-partlabel/*`
# devices match the already-installed disk: the running machine keeps booting
# and a fresh install recreates the same labels.
#
# Only the OS NVMe is managed: the backup HDD (sda, mounted at /var/backup by
# modules/nixos/backup.nix) and the Windows NVMe (nvme1n1) are left untouched.
{
  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/disk/by-id/nvme-Samsung_SSD_980_PRO_1TB_S5P2NG0NC04320K";
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
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };
}
