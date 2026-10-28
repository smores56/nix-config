# Server-side, host-only secrets for smortress, decrypted by sops-nix at
# activation from `secrets/smortress.yaml`. Declared here rather than in a shared
# module because the age recipients are host-scoped: only the host whose SSH host
# key decrypts that file may declare its secrets. Cross-host user secrets live in
# `secrets-common.nix` / `secrets/common.yaml`.
{
  config,
  lib,
  ...
}:
{
  config = lib.mkIf (config.networking.hostName == "smortress") {
    sops.defaultSopsFile = ../../secrets/smortress.yaml;
    # The host key paths are set once for every host in secrets-common.nix.
    # 0400 (sops-nix's default) and root ownership: only the root services that
    # read them (cloudflared, OpenTofu, and the alert units) need access.
    sops.secrets = {
      # One Cloudflare API token: OpenTofu (DNS/Access/Notifications) and the
      # email alert sender (Email Sending). Root-only; read at runtime.
      cloudflare-api-token = { };
      cloudflared-credentials = { };
      # The calibre OPDS password, read by the user's calibre-server unit; owned
      # by the user so the 0400 file is readable without root.
      calibre-password = {
        owner = config.machine.username;
        mode = "0400";
      };

      # Brave Search API key for LobeChat's web search. Only the container's
      # root-run preStart renders it into the env file, and Page Assist keeps
      # its own copy in the browser; sops-nix's root 0400 default is enough.
      # Maki's websearch uses tinyfish-api-key instead.
      brave-api-key = { };

      # A `repo`-scoped PAT, read only by the root GitHub-backup service
      # (modules/nixos/github-backup.nix). Root-owned, so the user's shell cannot
      # read it.
      github-repo-pat = {
        mode = "0400";
      };
    };

    # Repoint the tunnel daemon at the decrypted credentials. The API token is
    # read directly from its sops path by OpenTofu and the alert sender.
    webProxy.credentialsFile = config.sops.secrets.cloudflared-credentials.path;
  };
}
