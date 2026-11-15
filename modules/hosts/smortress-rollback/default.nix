# The 970 EVO as smortress's bootable fallback (homelab-platform#680, T6.2).
# It inherits smortress's host data so the two systems cannot drift; only the
# disk layout and the boot-time unlock differ, and those live in disko.nix and
# rollback.nix. Booting it needs the passphrase from Bitwarden and the sbctl
# bundle from the 980, not a Clevis share.
let
  smortress = import ../smortress/default.nix;
in
smortress
// {
  nixosModules = smortress.nixosModules ++ [ ./rollback.nix ];
}
