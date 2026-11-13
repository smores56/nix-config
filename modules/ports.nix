# Loopback ports shared by more than one file (a listener and its tunnel ingress, or a service
# and a client default); single-module ports live with that module. Ssh/llm/memory/chat/agent
# require Access; the data apps are served by the cluster, not here. A plain attrset outside
# modules/{features,desktop,nixos} so import-tree skips it; modules import it by relative path.
{
  llm = 8081;
  # The hosted assistant gateway: the guest listens, the host proxies it to the tunnel.
  agent = 42700;
  # The Letta App Server: same shape, a second guest listener and host relay.
  letta = 42701;
  immich = 2283;
  navidrome = 4533;
  ssh = 22;
  # Read by the wrapper's listener and the host tunnel ingress; the shim and CLI dial
  # https://memory.sammohr.dev.
  memoryMcp = 8182;
  # The cluster's NodePort for the in-cluster wrapper: the platform's Service manifest
  # must name the same literal (tests/policies/check.sh asserts it).
  memoryNodePort = 30082;
  # The memory-LLM gateway: Graphiti's extraction and embedding route.
  memoryLlmProxy = 8082;
  # Agent-VM capability brokers: guest-facing ports and the host broker ports they reach.
  agentNeuralwatt = 8083;
  agentTinyfish = 8084;
  agentSshRelay = 8085;
  agentBrokerMemory = 8186;
  filesMcp = 8185;
  openWebui = 3210;
  # The Kanbei chat relay: the private hostname route is Layer 4 and preserves the browser's
  # destination port, so cloudflared reaches this loopback listener on 443. systemd's socket
  # unit does the privileged bind; the relay itself runs unprivileged.
  kanbei = 443;
}
