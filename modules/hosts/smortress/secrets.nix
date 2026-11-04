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
    # Read by the user's calibre-server unit.
    calibre-password = {
      owner = config.machine.username;
      mode = "0400";
    };

    radicale-htpasswd = {
      owner = "radicale";
      mode = "0400";
    };
    restic-password = { };
    r2-access-key-id = { };
    r2-secret-access-key = { };

    # Read only by the root GitHub-backup service.
    github-repo-pat = {
      mode = "0400";
    };
  };

  webProxy.credentialsFile = config.sops.secrets.cloudflared-credentials.path;
}
