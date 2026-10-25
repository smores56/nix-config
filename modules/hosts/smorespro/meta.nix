# smorespro: Intel laptop, niri desktop with a fingerprint reader.
{
  system = "x86_64-linux";
  username = "smores";
  nixos = true;
  home = true;

  nixosOptions = {
    fingerprint.enable = true;
  };

  homeOptions = {
    # `pm` is an sshfs mount of smortress:/srv/proton, so the client holds no
    # Proton credential; smortress itself uses /srv/proton directly.
    protonDrive.enable = true;
  };
}
