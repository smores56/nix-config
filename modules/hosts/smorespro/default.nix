# Intel laptop: shared CLI/user tooling plus the Niri desktop.
{
  profiles = [
    ../../profiles/cli.nix
    ../../profiles/user-base.nix
    ../../profiles/ai-tools.nix
    ../../profiles/linux-desktop.nix
  ];
  # Host-local modules (read by modules/flake/configurations.nix): the LUKS +
  # Secure Boot chain and the greeter exist only on this machine.
  nixos = [
    ./boot.nix
    ./greeter.nix
  ];
}
