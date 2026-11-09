# Host-only: the age recipients are host-scoped. Cross-host secrets live in
# `modules/nixos/secrets-common.nix`.
{ config, ... }:
{
  sops.defaultSopsFile = ../../../secrets/smortress.yaml;
  # Root-owned 0400 unless noted.
  sops.secrets = {
    # Shared by OpenTofu and the email alert sender.
    cloudflare-api-token = { };
    cloudflared-credentials = { };
    restic-password = { };
    r2-access-key-id = { };
    r2-secret-access-key = { };

    # Read only by the root GitHub-backup service.
    github-repo-pat = {
      mode = "0400";
    };

    # Photo-triage: read/score key and album-writer key (see docs/key-rotation.md).
    photo-triage-immich-read-key = { };
    photo-triage-immich-album-key = { };
  };

  photoTriage = {
    readKeyFile = config.sops.secrets.photo-triage-immich-read-key.path;
    albumKeyFile = config.sops.secrets.photo-triage-immich-album-key.path;
  };

  webProxy.credentialsFile = config.sops.secrets.cloudflared-credentials.path;
}
