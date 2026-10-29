# smortress's boot chain: systemd stage 1, lanzaboote, and the TPM plumbing the
# Clevis `sss` policy needs. Host-scoped because the machine's own sbctl keys
# and its Tang pin only exist here (see T2 in #250).
#
# Order matters: `sudo sbctl create-keys` must run before the first rebuild
# with this module. `autoGenerateKeys` is deliberately off so a missing key
# bundle fails the bootloader install instead of writing artifacts the
# firmware will not trust.
{
  inputs,
  lib,
  pkgs,
  ...
}:
{
  imports = [ inputs.lanzaboote.nixosModules.lanzaboote ];

  # Scripted stage 1 is deprecated (removed in 26.11) and cannot express the
  # Clevis unit ordering. systemd stage 1 also gives the cryptsetup generator
  # the passphrase fallback when the Tang/TPM share cannot be satisfied.
  boot.initrd.systemd.enable = true;

  # The fTPM must be on in the firmware. Clevis orders its decrypt unit after
  # `tpm2.target`; without this the target never appears in the initrd and the
  # TPM share cannot unseal.
  security.tpm2.enable = true;
  boot.initrd.systemd.tpm2.enable = true;

  # Lanzaboote replaces the systemd-boot module enabled by base.nix; the
  # firmware must load the signed stub for PCR 7 to measure our Secure Boot
  # policy rather than a bootloader we did not sign.
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.lanzaboote = {
    enable = true;
    # Lives in the LUKS root, never in the store or the repo. Back it up
    # before any reinstall: the firmware has these keys in `db`.
    pkiBundle = "/var/lib/sbctl";
    autoGenerateKeys.enable = false;
    # 1 GiB ESP: lzbt keeps a kernel + initrd per generation.
    configurationLimit = 10;
  };

  # sbctl signs and enrolls; clevis binds and inspects the LUKS token; the
  # tpm2 tools verify the PCR 7 value before and after the bind.
  environment.systemPackages = [
    pkgs.sbctl
    pkgs.clevis
    pkgs.tpm2-tools
  ];
}
