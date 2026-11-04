# No NixOS activation to unlock a passphrase-wrapped identity, so the age key is a
# plaintext 0600 file. `secrets/smoreswork.yaml` is scoped to this machine.
{
  config,
  lib,
  ...
}:
let
  hostSecrets = ../../../secrets/smoreswork.yaml;
  commonSecretsFile = ../../../secrets/common.yaml;

  # Linked outside ~/.config, which the agent sandbox masks, so host and sandbox share paths.
  githubSecret = name: {
    path = "${config.home.homeDirectory}/.local/share/github/${name}";
  };

  # Deployed ahead of any Darwin consumer.
  commonSecrets = [
    "immich-agent-api-key"
    "neuralwatt-api-key"
    "smores-password-hash"
    "tinyfish-api-key"
  ];
in
{
  sops = {
    defaultSopsFile = hostSecrets;
    age.keyFile = "${config.home.homeDirectory}/.config/sops/smoreswork.key";
    secrets = {
      # Read by cloudflared-access as TUNNEL_SERVICE_TOKEN_ID/_SECRET, two
      # lines in that order.
      cloudflare-access-ssh-token = { };
      github-personal-pat = githubSecret "github-personal-pat" // {
        sopsFile = commonSecretsFile;
      };
      github-personal-signing-key = githubSecret "github-personal-signing-key" // {
        sopsFile = commonSecretsFile;
      };
      # The work account's bundle exists only on this machine.
      github-work-pat = githubSecret "github-work-pat";
      github-work-signing-key = githubSecret "github-work-signing-key";
    }
    // lib.genAttrs commonSecrets (_: {
      sopsFile = commonSecretsFile;
    });
  };
}
