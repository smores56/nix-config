# disko owns `/` and `/boot` (it derives `fileSystems`), so hardware.nix omits them.
# LUKS2 passphrase slot plus a Clevis `sss` slot (Tang + TPM2 on PCR 7) bound after
# first boot. Never run `nixos-rebuild` from this layout on a machine that is not
# already the 980's installed system. The 970 EVO keeps `-tmp` labels as a rollback
# (avoids duplicate partlabel symlinks). Only the OS NVMe is managed.
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
            type = "luks";
            name = "root";
            settings = {
              # Accepted trade: discard leaks which blocks are in use, not their contents.
              allowDiscards = true;
              # No fallbackToPassword: systemd stage 1 implies it and asserts
              # against the option.
            };
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
