# disko owns `/` and `/boot` (it derives `fileSystems`), so hardware.nix omits them.
# Partlabels are pinned to `EFI`/`root` (disko's default differs) to match the
# installed disk.
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
            type = "luks";
            name = "root";
            # Accepted trade: discard leaks which blocks are in use, not their contents.
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
