# sops-nix on a home-only Darwin host. There is no NixOS activation to unlock a
# passphrase-wrapped identity, so the age key is a plaintext 0600 file at
# `sops.age.keyFile` and the decrypted secrets land under
# `${xdg.configHome}/sops-nix/secrets`. `secrets/smoreswork.yaml` is scoped to
# this machine; the common file is shared with every host.
{
  config,
  lib,
  ...
}:
let
  hostSecrets = ../../../secrets/smoreswork.yaml;
  commonSecretsFile = ../../../secrets/common.yaml;

  # Each GitHub account's bundle (PAT + signing key) is linked outside
  # ~/.config, which the agent sandbox masks, so the same paths serve the host
  # and the sandbox (it allows exactly these resolved files).
  githubSecret = name: {
    path = "${config.home.homeDirectory}/.local/share/github/${name}";
  };

  # Deployed at the operator's request. Nothing on Darwin reads these yet:
  # maki's work profile is OpenAI-only, and the password hash and immich key
  # are NixOS/sandbox-only. They exist as 0400 files under
  # ${xdg.configHome}/sops-nix/secrets until a consumer is wired.
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
