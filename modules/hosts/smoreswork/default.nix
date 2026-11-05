# smoreswork: the employer's macOS laptop. Home-only (no NixOS config); its
# `system` drives the Darwin home build.
{
  system = "aarch64-darwin";
  username = "sam";
  home = true;

  profiles = [
    ../../profiles/cli.nix
    ../../profiles/user-base.nix
    ../../profiles/ai-tools.nix
    ../../profiles/darwin-work.nix
  ];
  homeModules = [
    ./sops.nix
    ./memory.nix
  ];

  user = {
    aiProfile = "work";
    shellAbbrs.m = "claude";
  };

  homeOptions = {
    # Ciphertext vault copy under ~/Sync, outside TCC-protected folders; only Cryptomator unlocks it.
    syncthing = {
      device = "smoreswork";
    };
  };
}
