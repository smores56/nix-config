# Declarative disk layout for smortress (see AGENTS.md). disko owns `/` and
# `/boot` — it derives `fileSystems` from here — so hardware.nix omits them.
#
# The 980 PRO is the final encrypted root: LUKS2 with the passphrase slot plus
# a Clevis `sss` slot (Tang + TPM2 on PCR 7) bound after the first boot (T2,
# #250). Never run `nixos-rebuild` from this layout on a machine that is not
# already the 980's installed system.
#
# The staging install used the 970 EVO with `EFI-tmp`/`root-tmp` labels to
# avoid duplicate `/dev/disk/by-partlabel/*` symlinks. The final system owns
# the canonical `EFI`/`root`; the 970 keeps the -tmp labels as a rollback.
#
# Only the OS NVMe is managed: the backup HDD (sda) and the 970 EVO are left
# untouched.
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
              # TRIM passes through to the NVMe; accepted trade: discard leaks
              # which blocks are in use, not their contents.
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
