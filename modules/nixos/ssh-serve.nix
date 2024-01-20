{ lib, ... }: {
  nix.sshServe.enable = true;
  nix.sshServe.keys = (import ../terminal/ssh/keys.nix { lib = lib; });
}
