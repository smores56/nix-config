# smoreswork: the employer's macOS laptop. Home-only (no NixOS config); its
# `system` drives the Darwin home build.
{
  system = "aarch64-darwin";
  username = "sam";
  home = true;

  user = {
    aiProfile = "work";
    brain.dir = "brain";
    shellAbbrs.m = "claude";
  };

  homeOptions = {
    # The work laptop holds a ciphertext copy of the vault under ~/Sync, outside
    # the TCC-protected folders, and unlocks it with the Cryptomator app only.
    syncthing = {
      device = "smoreswork";
    };
  };
}
