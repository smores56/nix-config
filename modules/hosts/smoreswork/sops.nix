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

  # Deployed at the operator's request. The PATs back the owner-selecting `gh`
  # wrapper and git credential helper (modules/features/github-credentials.nix).
  # Nothing on Darwin reads the rest yet: maki's work profile is OpenAI-only,
  # and the password hash and immich key are NixOS/sandbox-only. They exist as
  # 0400 files under ${xdg.configHome}/sops-nix/secrets until a consumer is
  # wired.
  commonSecrets = [
    "github-personal-pat"
    "github-work-pat"
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
    }
    // lib.genAttrs commonSecrets (_: {
      sopsFile = commonSecretsFile;
    });
  };
}
