# Loopback ports for the co-located services. One value each, read by the
# service listener, the tunnel ingress (for the exposed ones), and the clients'
# loopback forwards, so they cannot drift apart. The critical services
# (ssh/llm) also require Access; calibre and immich
# are public with their own app auth. A plain attrset (not a module): it lives
# outside modules/{features,desktop,nixos} so import-tree leaves it alone, and
# modules import it by relative path.
{
  llm = 8081;
  # Service listeners and their tunnel ingress read these, so the two cannot
  # drift apart.
  calibre = 8181;
  immich = 2283;
  ssh = 22;
  # Graphiti MCP; the tunnel ingress and the Maki client read it.
  memoryMcp = 8182;
}
