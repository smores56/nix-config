# smorespro: Intel laptop, niri desktop with a fingerprint reader.
{
  system = "x86_64-linux";
  username = "smores";
  nixos = true;
  home = true;

  # Shared profiles (they drive machine.graphical/wayland/workHost and the
  # server-profile assertion), not host-local modules.
  profiles = [
    ../../profiles/cli.nix
    ../../profiles/user-base.nix
    ../../profiles/ai-tools.nix
    ../../profiles/linux-desktop.nix
  ];
  # Host-local modules: the LUKS + Secure Boot chain, the greeter and the
  # fingerprint reader exist only on this machine.
  nixosModules = [
    ./boot.nix
    ./greeter.nix
    ./fprintd.nix
    ./secrets.nix
  ];

  nixosOptions = {
    # YubiKey sudo without an sshd: pam_rssh dials the local fido2-agent.
    sudoKey.enable = true;
    # The vault is shared by a home-manager user unit; lingering starts it at
    # boot without a login, and the watcher needs more inotify watches than the
    # default allows for Cryptomator's flattened layout.
    users.users.smores.linger = true;
    boot.kernel.sysctl."fs.inotify.max_user_watches" = 204800;
  };

  homeOptions = {
    # Ciphertext copy of the vault under ~/Sync; only Cryptomator unlocks it.
    syncthing = {
      device = "smorespro";
    };
  };
}
