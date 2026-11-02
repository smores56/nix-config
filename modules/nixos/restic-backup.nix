# restic is the backup driver: one encrypted repo offsite in R2 and one on the
# local 4.6 TB backup disk. It replaces the rclone dataset driver, so a single
# job covers the durable tree and every source is encrypted client-side.
{ config, lib, ... }:
let
  # Non-secret Cloudflare account id; the bucket is `restic-backup`.
  accountId = "385f7d47e2e8438fbda5d6f76d760434";

  common = {
    paths = [
      # The whole durable tree: vault ciphertext, wallpapers, media, the memory
      # export, the GitHub mirrors, Radicale and Open WebUI state. Nothing else
      # needs a second source path.
      "/var/lib/data"
    ];
    passwordFile = config.sops.secrets.restic-password.path;
    initialize = true;
    pruneOpts = [
      "--keep-daily 14"
      "--keep-weekly 8"
      "--keep-monthly 12"
    ];
    runCheck = true;
    timerConfig = {
      OnCalendar = "*-*-* 03:30:00";
      RandomizedDelaySec = "15m";
    };
  };
in
{
  sops.templates."restic-r2.env".content = ''
    AWS_ACCESS_KEY_ID=${config.sops.placeholder.r2-access-key-id}
    AWS_SECRET_ACCESS_KEY=${config.sops.placeholder.r2-secret-access-key}
    AWS_DEFAULT_REGION=auto
  '';

  services.restic.backups = {
    r2 = common // {
      repository = "s3:https://${accountId}.r2.cloudflarestorage.com/restic-backup";
      environmentFile = config.sops.templates."restic-r2.env".path;
    };
    local = common // {
      repository = "/var/backup/restic";
    };
  };

  # The restic module generates one unit per repo but exposes no `onFailure`
  # option, so the alert is attached to the generated units by name. %n expands
  # to the failing unit, so each repo's failure mails its own journal.
  # The local repo lives on the backup disk: wait for that mount, or a missing
  # disk would quietly fill the root filesystem instead of failing.
  systemd.services."restic-backups-r2".onFailure =
    lib.optional config.alerting.enable "cloudflare-email@%n.service";

  systemd.services."restic-backups-local" = {
    onFailure = lib.optional config.alerting.enable "cloudflare-email@%n.service";
    unitConfig.RequiresMountsFor = [ config.backup.mountPoint ];
  };
}
