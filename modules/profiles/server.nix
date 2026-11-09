# Headless server: NixOS services, backup, edge, and secrets.
{
  home = [
    ../features/calibre.nix
    # The store lives here, so the operator needs the same one-session mount for a sentinel
    # or an inspection.
    ../features/vault.nix
  ];
  nixos = [
    ../nixos/cloudflare-tofu.nix
    ../nixos/web-proxy.nix
    ../nixos/immich.nix
    ../nixos/navidrome.nix
    ../nixos/jupyter.nix
    ../nixos/open-webui.nix
    ../nixos/tinyfish-shim.nix
    ../nixos/llm.nix
    ../nixos/photo-triage.nix
    ../nixos/memory.nix
    ../nixos/filesearch.nix
    ../nixos/nvidia.nix
    ../nixos/backup.nix
    ../nixos/restic-backup.nix
    ../nixos/vault-sync.nix
    ../nixos/github-backup.nix
    ../nixos/alerting.nix
  ];
}
