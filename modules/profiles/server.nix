# Headless server: NixOS services, backup, edge, and secrets.
{
  home = [
    ../features/calibre.nix
    ../features/proton-drive.nix
  ];
  nixos = [
    ../nixos/secrets.nix
    ../nixos/cloudflare-tofu.nix
    ../nixos/web-proxy.nix
    ../nixos/immich.nix
    ../nixos/lobechat.nix
    ../nixos/llm.nix
    ../nixos/memory.nix
    ../nixos/filesearch.nix
    ../nixos/nvidia.nix
    ../nixos/backup.nix
    ../nixos/backup-datasets.nix
    ../nixos/github-backup.nix
    ../nixos/alerting.nix
    ../nixos/no-sleep.nix
  ];
}
