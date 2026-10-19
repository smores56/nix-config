# Loopback ports for the co-located services. One value each, read by the
# service listener, the tunnel ingress (for the exposed ones), and the clients'
# loopback forwards, so they cannot drift apart. Every port here is also a
# protected port in cloudflare_sync.py. A plain attrset (not a module): it lives
# outside modules/{features,desktop,nixos} so import-tree leaves it alone, and
# modules import it by relative path.
{
  llm = 8081;
  searx = 8899;
  ntfy = 2586;
  # The chat UI and its code-interpreter sandbox; only `chat` gets a tunnel
  # ingress, `jupyter` is reachable only by the chat UI over loopback.
  chat = 8080;
  jupyter = 8888;
  # Service listeners and their tunnel ingress read these, so the two cannot
  # drift apart.
  calibre = 8181;
  immich = 2283;
  navidrome = 4533;
  ssh = 22;
}
