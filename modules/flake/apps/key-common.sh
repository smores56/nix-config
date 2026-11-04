# Shared by key-backup and key-restore; the Nix wrapper substitutes `pubkeys`, the committed
# "<handle>\t<public key>" map from modules/lib/yubikey-keys.nix.
pubkeys="@PUBKEYS@"

first_two() {
  awk '{ print $1" "$2 }'
}

