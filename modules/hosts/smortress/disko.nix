# Declarative disk layout for smortress (see AGENTS.md). disko owns `/` and
# `/boot` — it derives `fileSystems` from here — so hardware.nix omits them.
#
# MIGRATION TARGET: the 970 EVO is the temporary staging system (T2, #270).
# The 980 PRO keeps its data until the final install, so this is only used
# with `disko` + `nixos-install` from the running 980 — never with
# `nixos-rebuild` on the 980 (it would declare `/` on the other disk).
#
# The staging disk's labels are deliberately `EFI-tmp`/`root-tmp`. The 980
# already owns `EFI`/`root`, and two partitions with the same PARTLABEL make
# `/dev/disk/by-partlabel/*` resolve to whichever device udev saw last. The
# final system on the 980 uses the canonical `EFI`/`root`; the 970 keeps the
# -tmp labels so it stays a safe rollback even while installed alongside.
#
# Only the OS NVMe is managed: the backup HDD (sda, mounted at /var/backup by
# modules/nixos/backup.nix) and the 980 PRO are left untouched.
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
          label = "EFI-tmp";
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
          label = "root-tmp";
          content = {
            type = "luks";
            name = "root";
            settings = {
              # TRIM passes through to the NVMe; accepted trade: discard leaks
              # which blocks are in use, not their contents.
              allowDiscards = true;
              # The passphrase slot is the mandatory recovery path; Clevis is
              # bound as an additional keyslot later, never the only one.
              # fallbackToPassword is implied by systemd stage 1 and would trip
              # its assertion if set here.
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
