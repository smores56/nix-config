# Syncthing device IDs. A device ID is the base32 SHA-256 of the device's
# self-signed certificate, i.e. public-key material, so it is safe to commit;
# each device's `key.pem` is the only secret. Pairing a peer is one line here —
# `syncthing device-id` prints the value on that host — and the folder is shared
# with every device in this table. A plain attrset (not a module): the module
# imports it by relative path.
{
  smortress = "DGDHUDO-5HJZ2BV-GGSYMRE-HE52WK2-CXSJIEU-3P5T4RJ-IJVYNXP-TN7TQQ6";
}
