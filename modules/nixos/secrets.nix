# Server-side secrets for smortress, decrypted by sops-nix at activation from
# the encrypted `secrets/smortress.yaml`. Declared on the host rather than a
# `dotfiles.*` knob because the age recipients are host-scoped: only the host
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
    sops.secrets = {
      cf-api-token = {
        mode = "0400";
      };
      cloudflared-credentials = {
        mode = "0400";
      };
      navidrome-env = {
        mode = "0400";
      };
      searxng-secret-key = {
        mode = "0400";
      };
    };

    # Repoint the consumers at the decrypted files. The option defaults stay
    # untouched so every other host still evaluates against the old /var/lib
    # paths.
    dotfiles.webProxy.apiTokenFile = config.sops.secrets.cf-api-token.path;
    dotfiles.webProxy.credentialsFile = config.sops.secrets.cloudflared-credentials.path;
    dotfiles.navidrome.environmentFile = config.sops.secrets.navidrome-env.path;
  };
}
