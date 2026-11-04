# Loopback ports shared by more than one file (a listener and its tunnel ingress, or a service
# and a client default); single-module ports live with that module. Ssh/llm/memory/chat require
# Access; calibre and immich are public with their own app auth. A plain attrset outside
# modules/{features,desktop,nixos} so import-tree skips it; modules import it by relative path.
{
  llm = 8081;
  calibre = 8181;
  immich = 2283;
  radicale = 5232;
  navidrome = 4533;
  ssh = 22;
  # Read by the wrapper's listener, its tunnel ingress and the generated Maki `mcp.toml`; the shim and CLI keep a matching default.
  memoryMcp = 8182;
  memoryEmbed = 8183;
  # The memory-LLM gateway: Graphiti's extraction route and the `neuralwatt` embedder.
  memoryLlmProxy = 8082;
  filesMcp = 8185;
  openWebui = 3210;
}
