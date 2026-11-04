# Shared by key-backup and key-restore. `pubkeys` is the committed
# "<handle>\t<public key>" map from modules/lib/yubikey-keys.nix, substituted by
# the Nix wrapper.
pubkeys="@PUBKEYS@"

first_two() {
  awk '{ print $1" "$2 }'
}

