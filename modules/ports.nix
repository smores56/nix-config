# Loopback ports for the co-located services. One value each, read by the
# service listener, the tunnel ingress (for the exposed ones), and the clients'
# loopback forwards, so they cannot drift apart. Every Access-protected service
# (ssh/llm/memory) requires Access; calibre and immich are public with their own
# app auth. A plain attrset (not a module): it lives outside
# modules/{features,desktop,nixos} so import-tree leaves it alone, and modules
# import it by relative path.
{
  llm = 8081;
  # Service listeners and their tunnel ingress read these, so the two cannot
  # drift apart.
  calibre = 8181;
  immich = 2283;
  ssh = 22;
  # The memory wrapper is the only tunnel target for memory (the raw Graphiti
  # MCP moved inside); the Maki shim and the `memory` CLI read memoryMcp.
  memoryMcp = 8182;
  # Raw Graphiti MCP. Loopback only and never tunneled: the wrapper on
  # memoryMcp owns validation, dedup, and work refusal.
  memoryGraphiti = 8184;
}
