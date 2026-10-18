# Tunnel hostnames whose Cloudflare Access must never be removed: a typo that
# clears `access.enable` would otherwise publish sshd/the LLM/SearXNG/ntfy to
# the internet. Read by modules/nixos/web-proxy.nix (the evaluation-time
# assertion) and mirrored by PROTECTED_SUBDOMAINS in
# modules/features/cloudflare/cloudflare_sync.py (the reconciler's second line of
# defence); a flake check keeps the two copies in sync. A plain attrset (not a
# module): it lives outside modules/{features,desktop,nixos} so import-tree
# leaves it alone, and modules import it by relative path.
{
  subdomains = [
    "ssh"
    "llm"
    "searx"
    "ntfy"
  ];
}
