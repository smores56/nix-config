# Loopback ports shared by more than one file (a listener and its tunnel ingress, or a service
# and a client default); single-module ports live with that module. Ssh/llm/memory/chat/agent
# require Access; calibre and immich are public with their own app auth. A plain attrset outside
# modules/{features,desktop,nixos} so import-tree skips it; modules import it by relative path.
{
  llm = 8081;
  # The hosted assistant gateway: the guest listens, the host proxies it to the tunnel.
  agent = 42700;
  # The Letta App Server: same shape, a second guest listener and host relay.
  letta = 42701;
  calibre = 8181;
  immich = 2283;
  navidrome = 4533;
  ssh = 22;
  # Read by the wrapper's listener, its tunnel ingress and the generated Maki `mcp.toml`; the shim and CLI keep a matching default.
  memoryMcp = 8182;
  # The memory-LLM gateway: Graphiti's extraction and embedding route.
  memoryLlmProxy = 8082;
  # Agent-VM capability brokers: guest-facing ports and the host broker ports they reach.
  agentNeuralwatt = 8083;
  agentTinyfish = 8084;
  agentSshRelay = 8085;
  agentBrokerMemory = 8186;
  agentBrokerCalibre = 8187;
  filesMcp = 8185;
  openWebui = 3210;
  # The Kanbei chat relay: the private hostname route is Layer 4 and preserves the browser's
  # destination port, so cloudflared reaches this loopback listener on 443. systemd's socket
  # unit does the privileged bind; the relay itself runs unprivileged.
  kanbei = 443;
}
