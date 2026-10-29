# Headless server: shared CLI/user tooling plus NixOS services.
{
  profiles = [
    ../../profiles/cli.nix
    ../../profiles/user-base.nix
    ../../profiles/ai-tools.nix
    ../../profiles/server.nix
  ];
  # Host-local modules (read by modules/flake/configurations.nix): the Secure
  # Boot + TPM boot chain exists only on this machine.
  nixos = [ ./boot.nix ];
}
