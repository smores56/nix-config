# Server-side secrets for smortress, decrypted by sops-nix at activation from
# the encrypted `secrets/smortress.yaml`. Declared on the host rather than as
# a shared option because the age recipients are host-scoped: only the host
# whose ssh host key decrypts that file may declare its secrets. Other hosts
# import the sops module but declare no secrets, so nothing runs there.
{
  config,
  lib,
  ...
}:
{
  config = lib.mkIf (config.networking.hostName == "smortress") {
    sops.defaultSopsFile = ../../secrets/smortress.yaml;
    # The `smortress` age recipient in `.sops.yaml` is derived from the host
    # ed25519 key. sops-nix would import that key by default once openssh is
    # enabled (exposeSsh), but it is named explicitly so a default change cannot
    # quietly break decryption; the key must already exist on the host — out of
    # band, like the secrets it decrypts.
    sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
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

      # maki's hosted-inference key; the fish init exports it from this path, so
      # the user must be able to read it.
      neuralwatt-api-key = {
        owner = config.machine.username;
        mode = "0400";
        # The memory gateway reads the credential once at start, so a new key
        # only reaches it if the unit restarts.
        restartUnits = [ "memory-llm-proxy.service" ];
      };

      # Brave Search API key; the fish init exports it for maki's websearch
      # plugin and Page Assist uses its own copy in the browser.
      brave-api-key = {
        owner = config.machine.username;
        mode = "0400";
      };

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
