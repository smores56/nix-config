# smorespro's boot chain: a LUKS root unlocked by the TPM with a PIN, signed by
# lanzaboote so the firmware verifies what the TPM measured. Host-scoped: a
# machine that has not enrolled its own sbctl keys must not inherit this.
{
  inputs,
  lib,
  pkgs,
  ...
}:
{
  imports = [ inputs.lanzaboote.nixosModules.lanzaboote ];

  # Scripted stage 1 is deprecated (removed in 26.11) and cannot express
  # tpm2-device=auto; systemd stage 1 also gives the cryptsetup generator the
  # TPM PIN prompt.
  boot.initrd.systemd.enable = true;

  # Ask the TPM for a key from the slot enrolled with
  # `systemd-cryptenroll --tpm2-device=auto --tpm2-with-pin=yes
  # --tpm2-pcrs=7`; the passphrase slot stays as the recovery path, so a
  # missing/cleared fTPM or a failed PIN still boots.
  boot.initrd.luks.devices.root.crypttabExtraOpts = [ "tpm2-device=auto" ];

  # Lanzaboote replaces the systemd-boot module (base.nix enables it); the
  # firmware must load the signed stub for PCR 7 to mean anything.
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.lanzaboote = {
    enable = true;
    # Lives in the LUKS root, never in the store or the repo.
    pkiBundle = "/var/lib/sbctl";
    # Keys were generated on first boot by the generate-sb-keys service (the
    # first install cannot carry them). This is deliberately off now: it also
    # implies allowUnsigned, and a missing key pair must fail the bootloader
    # install instead of silently writing unsigned artifacts.
    autoGenerateKeys.enable = false;
    # 1 GiB ESP: lzbt keeps a kernel + initrd per generation.
    configurationLimit = 10;
  };

  # The operator runs `sbctl status` and `sbctl enroll-keys --microsoft`; the
  # firmware side is manual work either way.
  environment.systemPackages = [ pkgs.sbctl ];
}
