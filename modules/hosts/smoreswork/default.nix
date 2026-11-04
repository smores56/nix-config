# smoreswork: the employer's macOS laptop. Home-only (no NixOS config); its
# `system` drives the Darwin home build.
{
  system = "aarch64-darwin";
  username = "sam";
  home = true;

  # Shared profiles (they drive machine.graphical/wayland/workHost and the
  # server-profile assertion), not host-local modules.
  profiles = [
    ../../profiles/cli.nix
    ../../profiles/user-base.nix
    ../../profiles/ai-tools.nix
    ../../profiles/darwin-work.nix
  ];
  homeModules = [ ./sops.nix ];

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
