# Constants shared by the host access module and the kanbei guest module. A plain attrset
# (not a module) so import-tree skips it; both sides must agree on the vsock ports or the relay
# dials a dead port and the certificate request never completes.
{
  hostname = "kanbei.sammohr.dev";
  # Guest listeners (AF_VSOCK). TLS terminates at the chat port in the guest.
  chatVsockPort = 10000;
  certVsockPort = 10001;
  # Host CID as seen from a guest (VMADDR_CID_HOST).
  hostVsockCid = 2;
  # Guest-side certificate material: 0700 root, key/cert 0400 root.
  guestTlsDir = "/var/lib/kanbei/tls";
  # The TLS frontend (unit name without the .service suffix).
  guestUiUnit = "kanbei-ui";
  # Host-side ACME state (Certbot account, work and log directories).
  acmeStateDir = "/var/lib/kanbei-acme";
  # Relay identity: its own UID and no group members beyond the unit.
  relayUser = "kanbei-relay";
  # The tunnel runs as a DynamicUser, so it joins this group to reach the relay socket.
  tunnelGroup = "kanbei-tunnel";
}
