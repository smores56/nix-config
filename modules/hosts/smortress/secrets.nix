# Host-only: the age recipients are host-scoped. Cross-host secrets live in
# `modules/nixos/secrets-common.nix`.
{ config, lib, ... }:
{
  sops.defaultSopsFile = ../../../secrets/smortress.yaml;
  # Root-owned 0400 unless noted.
  sops.secrets = lib.mkMerge [
    {
      # Shared by OpenTofu and the email alert sender.
      cloudflare-api-token = { };
      cloudflared-credentials = { };
      restic-password = { };
      r2-access-key-id = { };
      r2-secret-access-key = { };

      # The GitHub mirror PAT moved to homelabs-platform (T9). Its encrypted yaml key
      # is still in secrets/smortress.yaml; delete it by hand (docs/manual-steps.md).

    }

    # The phone's Syncthing folder password. The phone sets the same value when it
    # shares the folder to this host; kanbei stages it into its LUKS volume. 0400 root,
    # never readable by `smores` (docs/kanbei-phone.md). Gated on the guest: the pipeline
    # only exists while `kanbeiVm.enable` is set, and the key is not in
    # `secrets/smortress.yaml` yet, so an unconditional declaration fails every switch.
    (lib.mkIf (config.kanbeiVm.enable or false) {
      phone-folder-password = {
        restartUnits = [ "kanbei-phone-password.service" ];
      };
    })

    # The five ingest source contracts (docs/kanbei-ingest.md). sops-nix owns
    # /run/secrets and prunes every file it does not manage there, so the staging
    # units depend on these declarations and not on a file a human dropped in.
    # Root-only 0400 is the default, which is what the units read.
    (lib.mkIf (config.ingestVm.enable or false) {
      ingest-tuta-env = { };
      ingest-finance-env = { };
      ingest-brave-env = { };
      ingest-immich-env = { };
      ingest-search-env = { };
    })
  ];

  webProxy.credentialsFile = config.sops.secrets.cloudflared-credentials.path;
}
