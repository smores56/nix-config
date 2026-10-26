# smorespro: Intel laptop, niri desktop with a fingerprint reader.
{
  system = "x86_64-linux";
  username = "smores";
  nixos = true;
  home = true;

  nixosOptions = {
    fingerprint.enable = true;
    # PIV + PIN at the greeter (pam_p11 matches ~/.eid/authorized_certificates).
    # Without the key in the reader it returns AUTHINFO_UNAVAIL, so the password
    # and fingerprint paths still work; TTY login stays password-only.
    security.pam.services.greetd.p11Auth = true;
  };

  homeOptions = {
    # `pm` is an sshfs mount of smortress:/srv/proton, so the client holds no
    # Proton credential; smortress itself uses /srv/proton directly.
    protonDrive.enable = true;
  };
}
