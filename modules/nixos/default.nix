{ ... }: {
  imports = [
    ./i18n.nix
    ./disks.nix
    ./security.nix
    ./bluetooth.nix
    ./networking.nix
  ];
}
