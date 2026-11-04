# restic is the backup driver: one encrypted repo offsite in R2 and one on the
# local 4.6 TB backup disk. A single job covers the durable tree and every
# source is encrypted client-side.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  hardening = import ../lib/hardening.nix;
  # Non-secret Cloudflare account id; the bucket is `restic-backup`.
  accountId = "385f7d47e2e8438fbda5d6f76d760434";

  # The Immich database is the photo library's source of truth, so a dump has
  # to land inside the tree before restic walks it. The postgres user owns the
  # directory (it writes the dump) and restic runs as root (it reads it).
  dbDir = "/var/lib/data/db";
  dumpFile = "${dbDir}/immich.dump";

  dbDump = pkgs.writeShellScript "restic-db-dump" ''
    set -euo pipefail
    tmp=${lib.escapeShellArg (dumpFile + ".tmp")}
    trap 'rm -f "$tmp"' EXIT
    ${config.services.postgresql.package}/bin/pg_dump -Fc --no-owner immich > "$tmp"
    mv "$tmp" ${lib.escapeShellArg dumpFile}
  '';

  common = {
    paths = [
      # The whole durable tree: vault ciphertext, wallpapers, media, the memory
      # export, the GitHub mirrors, Radicale and Open WebUI state. Nothing else
      # needs a second source path.
      "/var/lib/data"
    ];
    passwordFile = config.sops.secrets.restic-password.path;
    pruneOpts = [
      "--keep-daily 14"
      "--keep-weekly 8"
      "--keep-monthly 12"
    ];
    runCheck = true;
    timerConfig = {
      OnCalendar = "*-*-* 03:30:00";
      RandomizedDelaySec = "15m";
      # A host asleep at 03:30 still gets its run once it comes back.
      Persistent = true;
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
      # Only R2 initialises on its own: a fresh bucket is expected, so the first
      # run creates the repo. The local repo must NOT: an empty-but-mounted
      # /var/backup (fresh ext4, wrong disk) would otherwise initialise a new
      # repo and report success, hiding the missing backup disk. Leaving it
      # unset makes the first run fail and the onFailure alert fire; the
      # operator creates it once by hand (modules/features/backup/README.md).
      initialize = true;
    };
    local = common // {
      repository = "/var/backup/restic";
    };
  };

  # The restic module generates one unit per repo but exposes no `onFailure`
  # option, so the alert is attached to the generated units by name. %n expands
  # to the failing unit, so each repo's failure mails its own journal.
  # Both units want a fresh database dump first: `wants` rather than `requires`,
  # so a database that is down delays nothing and the tree is still backed up.
  systemd.tmpfiles.rules = [ "d ${dbDir} 0700 postgres postgres -" ];

  systemd.services.restic-db-dump = {
    description = "Dump the Immich database into the durable tree";
    after = [ "postgresql.service" ];
    requires = [ "postgresql.service" ];
    path = [ pkgs.coreutils ];
    onFailure = [ "cloudflare-email@%n.service" ];
    serviceConfig = hardening // {
      Type = "oneshot";
      User = "postgres";
      Group = "postgres";
      ExecStart = dbDump;
      TimeoutStartSec = "1h";
      ReadWritePaths = [ dbDir ];
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      ProtectClock = true;
      ProtectHostname = true;
      RestrictSUIDSGID = true;
      RestrictRealtime = true;
      LockPersonality = true;
      # pg_dump uses the local Unix socket; no network is needed.
      RestrictAddressFamilies = [ "AF_UNIX" ];
    };
  };

  systemd.services."restic-backups-r2" = {
    onFailure = [ "cloudflare-email@%n.service" ];
    wants = [ "restic-db-dump.service" ];
    after = [ "restic-db-dump.service" ];
  };

  # The local repo lives on the backup disk: wait for that mount, or a missing
  # disk would quietly fill the root filesystem instead of failing.
  systemd.services."restic-backups-local" = {
    onFailure = [ "cloudflare-email@%n.service" ];
    unitConfig.RequiresMountsFor = [ "/var/backup" ];
    wants = [ "restic-db-dump.service" ];
    after = [ "restic-db-dump.service" ];
  };
}
