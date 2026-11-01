# restic is the backup driver: one encrypted repo offsite in R2 and one on the
# local 4.6 TB backup disk. It replaces the rclone dataset driver, so a single
# job covers the durable tree and every source is encrypted client-side.
{ config, lib, ... }:
let
  # Non-secret Cloudflare account id; the bucket is `restic-backup`.
  accountId = "385f7d47e2e8438fbda5d6f76d760434";

  common = {
    paths = [
      "/var/lib/data"
      "/var/lib/memory/export"
      "/var/lib/github-mirrors"
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
}
