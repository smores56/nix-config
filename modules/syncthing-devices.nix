# Syncthing device IDs: the hash of each device's public certificate, so safe to commit (`key.pem`
# is the secret). Pairing a peer is one line here (`syncthing device-id` on that host); the vault
# and todo folders are shared with every device in the table. A plain attrset the module imports
# by relative path.
{
  smortress = "DGDHUDO-5HJZ2BV-GGSYMRE-HE52WK2-CXSJIEU-3P5T4RJ-IJVYNXP-TN7TQQ6";
  smorespro = "HYVRSZX-BJVBP6B-KHRNJBU-4AX3NSP-ROKHJIZ-ZDW5SUQ-G2AUTUQ-MRQWDQ2";
  # Syncthing-Fork on the phone (com.github.catfriend1.syncthingfork); it configures its
  # own folder path. This is the only peer of the `phone` receive-encrypted folder
  # (`modules/nixos/vault-sync.nix`, docs/kanbei-phone.md); the folder id on the phone
  # must be `phone`.
  phone = "EBFGS6E-QH3E3XF-2LJKWGW-ST6I4L2-IISJRXQ-REBYRU4-S6LH4XY-DPRZMQ4";
}
