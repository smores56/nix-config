{ lib, ... }: {
  home.file.".ssh/authorized_keys".text = builtins.concatStringsSep "\n" (import ./keys.nix { lib = lib; });
}
