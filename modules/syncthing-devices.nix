# Syncthing device IDs. A device ID is the base32 SHA-256 of the device's
# self-signed certificate, i.e. public-key material, so it is safe to commit;
# each device's `key.pem` is the only secret. Pairing a peer is one line here —
# `syncthing device-id` prints the value on that host — and the folder is shared
# with every device in this table. A plain attrset (not a module): the module
# imports it by relative path.
{
  smortress = "DGDHUDO-5HJZ2BV-GGSYMRE-HE52WK2-CXSJIEU-3P5T4RJ-IJVYNXP-TN7TQQ6";
  smorespro = "HYVRSZX-BJVBP6B-KHRNJBU-4AX3NSP-ROKHJIZ-ZDW5SUQ-G2AUTUQ-MRQWDQ2";
  smoreswork = "RTXUPMS-RSVZ4WH-SLGCCNN-OF74ZZ5-OZFIQFG-AB5IJ7V-MSIVFKM-CTONNA5";
  # Syncthing-Fork on the phone (com.github.catfriend1.syncthingfork). The
  # phone configures its own folder path; the table only makes the rest of the
  # fleet share the folder with it.
  phone = "EBFGS6E-QH3E3XF-2LJKWGW-ST6I4L2-IISJRXQ-REBYRU4-S6LH4XY-DPRZMQ4";
}
