# The fallback differs from the 980 in three ways.
#
# Clevis is off: the committed root.jwe is bound to the 980's LUKS header, its
# sss policy needs the Tang network in the initrd, and an emergency boot is
# attended by definition, so the passphrase prompt is the right unlock. The
# hostname stays `smortress` so sops paths, the tunnel identity and every
# service expectation survive the switch.
#
# The AI plane is off: `kanbei`'s fixed-output deno cache is not reproducible
# (every build hashes differently), so a fresh install of the pinned revision
# cannot build it, and both the kanbei volume and the ingest state live on the
# 980's root, which the fallback never owns. Its job is the data plane and the
# primary repository. With `kanbeiVm` off `modules/nixos/llm.nix` would turn the
# host llama-cpp server on; that would pull the 15G model in for a guest that is
# not running, so it is off too.
{ lib, ... }:
{
  boot.initrd.clevis.enable = lib.mkForce false;
  networking.hostName = lib.mkForce "smortress";

  kanbeiVm.enable = lib.mkForce false;
  ingestVm.enable = lib.mkForce false;
  services.llama-cpp.enable = lib.mkForce false;
}
