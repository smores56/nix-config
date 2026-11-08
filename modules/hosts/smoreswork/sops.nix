# No NixOS activation to unlock a passphrase-wrapped identity, so the age key is a
# plaintext 0600 file. `secrets/smoreswork.yaml` is scoped to this machine.
{
  config,
  ...
}:
let
  hostSecrets = ../../../secrets/smoreswork.yaml;
  commonSecretsFile = ../../../secrets/common.yaml;
in
{
  sops = {
    defaultSopsFile = hostSecrets;
    age.keyFile = "${config.home.homeDirectory}/.config/sops/smoreswork.key";
    secrets = {
      # Read by cloudflared-access as TUNNEL_SERVICE_TOKEN_ID/_SECRET, two
      # lines in that order.
      cloudflare-access-ssh-token = { };
      github-personal-pat.sopsFile = commonSecretsFile;
      github-personal-signing-key.sopsFile = commonSecretsFile;
      calibre-password.sopsFile = commonSecretsFile;
      # The work account's bundle exists only on this machine.
      github-work-pat = { };
      github-work-signing-key = { };
      # The employer's key for memory embeddings, read at run time by the memory LLM proxy.
      openai-api-key = { };
    };
  };
}
