# Loopback ports for the tunnel-exposed services. One value each, read by the
# service listener, the tunnel ingress, and the clients' loopback forwards, so
# the three cannot drift apart. A plain attrset (not a module): it lives outside
# modules/{features,desktop,nixos} so import-tree leaves it alone, and modules
# import it by relative path.
{
  llm = 8081;
  searx = 8899;
}
