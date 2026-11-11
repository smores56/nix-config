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

      # Photo-triage: read/score key and album-writer key (see docs/key-rotation.md).
      photo-triage-immich-read-key = { };
      photo-triage-immich-album-key = { };

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
  ];

  photoTriage = {
    readKeyFile = config.sops.secrets.photo-triage-immich-read-key.path;
    albumKeyFile = config.sops.secrets.photo-triage-immich-album-key.path;
  };

  webProxy.credentialsFile = config.sops.secrets.cloudflared-credentials.path;
}
