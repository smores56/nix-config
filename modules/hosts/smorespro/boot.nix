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

  # Scripted stage 1 cannot express tpm2-device=auto.
  boot.initrd.systemd.enable = true;

  # Slot enrolled with `systemd-cryptenroll --tpm2-device=auto --tpm2-with-pin=yes
  # --tpm2-pcrs=7`; the passphrase slot stays as recovery.
  boot.initrd.luks.devices.root.crypttabExtraOpts = [ "tpm2-device=auto" ];

  # Replaces systemd-boot (base.nix); PCR 7 needs the signed stub.
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.lanzaboote = {
    enable = true;
    # Lives in the LUKS root, never in the store or repo.
    pkiBundle = "/var/lib/sbctl";
    # Off: it implies allowUnsigned, and a missing key pair must fail the install.
    autoGenerateKeys.enable = false;
    # 1 GiB ESP: lzbt keeps a kernel + initrd per generation.
    configurationLimit = 10;
  };

  environment.systemPackages = [ pkgs.sbctl ];
}
