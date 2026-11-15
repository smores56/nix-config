# The fallback differs from the 980 in four ways.
#
# Clevis is off: the committed root.jwe is bound to the 980's LUKS header, its
# sss policy needs the Tang network in the initrd, and an emergency boot is
# attended by definition, so the passphrase prompt is the right unlock. The
# devices map goes too, or `luksroot.nix` still renders a clevis unit per device.
# The hostname stays `smortress` so sops paths, the tunnel identity and every
# service expectation survive the switch.
#
# The AI plane is off: `kanbei`'s fixed-output deno cache is not reproducible
# (every build hashes differently), so a fresh install of the pinned revision
# cannot build it, and both the kanbei volume and the ingest state live on the
# 980's root, which the fallback never owns. `machine.gpu` off keeps `nvidia.nix`
# and `llm.nix` inert, which also avoids an unsigned `nvidia_uvm` failing
# modules-load under Secure Boot and the 15G model in the closure.
#
# No restic backup runs here. The jobs would not fail safely: the paths are
# empty directories on this host, the sops credentials still work, and an empty
# snapshot lands in the same `host,paths` group as the real ones, so a prune
# would delete the restore points the fallback exists to use. Restores are
# manual `restic` invocations against the HDD repository.
{ lib, ... }:
{
  machine.gpu = false;

  boot.initrd.clevis = {
    enable = lib.mkForce false;
    devices = lib.mkForce { };
  };
  networking.hostName = lib.mkForce "smortress";

  kanbeiVm.enable = lib.mkForce false;
  ingestVm.enable = lib.mkForce false;

  # No backup jobs here: per-backup entries carry their own timer, so the whole
  # set goes rather than a flag. Restores are manual `restic` invocations.
  services.restic.backups = lib.mkForce { };
}
