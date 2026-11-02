# smorespro: Intel laptop, niri desktop with a fingerprint reader.
{
  system = "x86_64-linux";
  username = "smores";
  nixos = true;
  home = true;

  nixosOptions = {
    fingerprint.enable = true;
    # YubiKey sudo without an sshd: pam_rssh dials the local fido2-agent.
    sudoKey.enable = true;
    # The vault is shared by a home-manager user unit; lingering starts it at
    # boot without a login, and the watcher needs more inotify watches than the
    # default allows for Cryptomator's flattened layout.
    users.users.smores.linger = true;
    boot.kernel.sysctl."fs.inotify.max_user_watches" = 204800;
  };

  homeOptions = {
    # `pm` is an sshfs mount of smortress:/srv/proton, so the client holds no
    # Proton credential; smortress itself uses /srv/proton directly.
    protonDrive.enable = true;
    # Ciphertext copy of the vault under ~/Sync; only Cryptomator unlocks it.
    syncthing = {
      enable = true;
      device = "smorespro";
    };
  };
}
