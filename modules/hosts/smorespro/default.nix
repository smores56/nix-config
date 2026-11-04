# smorespro: Intel laptop, niri desktop with a fingerprint reader.
{
  system = "x86_64-linux";
  username = "smores";
  nixos = true;
  home = true;

  profiles = [
    ../../profiles/cli.nix
    ../../profiles/user-base.nix
    ../../profiles/ai-tools.nix
    ../../profiles/maki.nix
    ../../profiles/linux-desktop.nix
  ];
  nixosModules = [
    ./boot.nix
    ./greeter.nix
    ./fprintd.nix
    ./secrets.nix
  ];

  nixosOptions = {
    # YubiKey sudo without an sshd: pam_rssh dials the local fido2-agent.
    sudoKey.enable = true;
  };

  homeOptions = {
    # Ciphertext copy of the vault under ~/Sync; only Cryptomator unlocks it.
    syncthing = {
      device = "smorespro";
    };
  };
}
