# Headless server: NixOS services, backup, edge, and secrets.
{
  home = [
    ../features/calibre.nix
  ];
  nixos = [
    ../nixos/cloudflare-tofu.nix
    ../nixos/web-proxy.nix
    ../nixos/immich.nix
    ../nixos/radicale.nix
    ../nixos/navidrome.nix
    ../nixos/jupyter.nix
    ../nixos/open-webui.nix
    ../nixos/tinyfish-shim.nix
    ../nixos/llm.nix
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
