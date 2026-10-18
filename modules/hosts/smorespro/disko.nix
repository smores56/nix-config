# Declarative disk layout for smorespro (see AGENTS.md). disko owns `/` and
# `/boot` — it derives `fileSystems` from here — so hardware.nix omits them.
#
# The partition labels are pinned to `EFI`/`root` (disko's default would be
# `disk-main-boot`/`disk-main-root`) so the derived `/dev/disk/by-partlabel/*`
# devices match the already-installed disk: the running machine keeps booting
# and a fresh install recreates the same labels.
#
# The laptop has a single NVMe; it is the only disk managed.
{
  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/disk/by-id/nvme-XPG_MARS_970_PLUS_2Q02291QG22Y";
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
