# Employer macOS laptop: shared CLI/user tooling plus the work profile.
{
  profiles = [
    ../../profiles/cli.nix
    ../../profiles/user-base.nix
    ../../profiles/ai-tools.nix
    ../../profiles/darwin-work.nix
  ];
}
