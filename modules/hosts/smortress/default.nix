# Headless server: shared CLI/user tooling plus NixOS services.
{
  profiles = [
    ../../profiles/cli.nix
    ../../profiles/user-base.nix
    ../../profiles/ai-tools.nix
    ../../profiles/server.nix
  ];
}
