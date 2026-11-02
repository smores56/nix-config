# Loopback ports shared by more than one file: a service listener and its
# tunnel ingress, or a service and a client default. Ports used by a single
# module live with that module (the raw Graphiti MCP port, for example, is
# internal to modules/nixos/memory.nix) so this file cannot claim to be a single
# source it is not. Every Access-protected service (ssh/llm/memory/chat)
# requires Access; calibre and immich are public with their own app auth. A plain
# attrset (not a module): it lives outside modules/{features,desktop,nixos} so
# import-tree leaves it alone, and modules import it by relative path.
{
  llm = 8081;
  # Listener and tunnel ingress read this.
  calibre = 8181;
  immich = 2283;
  # Radicale CalDAV/CardDAV listener and its tunnel ingress.
  radicale = 5232;
  # Navidrome Subsonic listener and its tunnel ingress.
  navidrome = 4533;
  ssh = 22;
  # The wrapper's listener, its tunnel ingress, and the generated Maki
  # `mcp.toml` environment read this; the shim and CLI keep a matching
  # standalone default.
  memoryMcp = 8182;
  # bge-m3: memory's local embedder, used when `memory.embedder` is `local`.
  memoryEmbed = 8183;
  # The memory-LLM gateway: Graphiti's extraction route and memory's embedder
  # when `memory.embedder` is `neuralwatt`.
  memoryLlmProxy = 8082;
  # Read-only file-search MCP: listener and Open WebUI's tool connection.
  filesMcp = 8185;
  # Open WebUI listener and its tunnel ingress.
  openWebui = 3210;
}
