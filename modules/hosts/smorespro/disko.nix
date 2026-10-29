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
          # The root filesystem stays the same; only its container changes, so
          # /dev/disk/by-partlabel/root is now a LUKS header and
          # /dev/mapper/root is the ext4 the mountpoint names.
          content = {
            type = "luks";
            name = "root";
            # TRIM passes through to the NVMe; without it the disk never learns
            # which blocks are free and write amplification grows. Accepted
            # trade: discard leaks which blocks are in use, not their contents.
            settings.allowDiscards = true;
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
