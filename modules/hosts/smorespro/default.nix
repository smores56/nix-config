# Intel laptop: shared CLI/user tooling plus the Niri desktop.
{
  profiles = [
    ../../profiles/cli.nix
    ../../profiles/user-base.nix
    ../../profiles/ai-tools.nix
    ../../profiles/linux-desktop.nix
  ];
}
