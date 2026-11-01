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
  hostSecrets = ../../secrets/smoreswork.yaml;
  commonSecretsFile = ../../secrets/common.yaml;

  # The operator creates the host file (docs/manual-steps.md); until it is
  # committed the flake must still evaluate, so the module is gated on it.
  commonSecrets = [
    "github-personal-pat"
    "github-work-pat"
    "immich-agent-api-key"
    "neuralwatt-api-key"
    "smores-password-hash"
    "tinyfish-api-key"
  ];
in
lib.mkIf (builtins.pathExists hostSecrets) {
  sops = {
    defaultSopsFile = hostSecrets;
    age.keyFile = "${config.home.homeDirectory}/.config/sops/smoreswork.key";
    secrets =
      {
        # Read by cloudflared-access as TUNNEL_SERVICE_TOKEN_ID/_SECRET, two
        # lines in that order.
        cloudflare-access-ssh-token = { };
      }
      // lib.genAttrs commonSecrets (_: { sopsFile = commonSecretsFile; });
  };
}
