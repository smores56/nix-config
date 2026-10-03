# Daily Immich backup. pg_dump + the managed library become restic snapshots on
# the generic backup disk; the restic repo is then mirrored offsite to Proton
# with `rclone copy` (append-only). Deletions on smortress therefore never reach
# either copy: restic keeps dated snapshots, and the offsite mirror is never
# pruned. `rclone` comes from the overlay that pulls 1.75.1 for the Proton fixes.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles.immich;
  bcfg = cfg.backup;
  disk = config.dotfiles.backup;

  immich-backup = pkgs.writeShellScriptBin "immich-backup" ''
    exec ${pkgs.python3}/bin/python3 ${./../features/immich/immich_backup.py} "$@"
  '';

  args = lib.concatStringsSep " " [
    "--repo ${disk.mountPoint}/immich/restic"
    "--library ${cfg.mediaLocation}/library"
    "--dump-file ${disk.mountPoint}/immich/dump/immich.sql"
    "--password-file ${bcfg.passwordFile}"
    "--rclone-config ${bcfg.rcloneConfig}"
    "--remote ${bcfg.protonRemote}"
    "--remote-path ${bcfg.protonPath}"
  ];
in
{
  config = lib.mkIf (cfg.enable && bcfg.enable) {
    assertions = [
      {
        assertion = disk.enable;
        message = "dotfiles.immich.backup requires dotfiles.backup (the backup disk) to be enabled.";
      }
    ];

    environment.systemPackages = [
      immich-backup
      pkgs.restic
      pkgs.rclone
    ];

    # The mount is root-owned; give the immich service user its tenant folder.
    systemd.tmpfiles.rules = [
      "d ${disk.mountPoint}/immich 0700 immich immich -"
    ];

    systemd.services.immich-backup = {
      description = "Immich backup: pg_dump + restic snapshot + append-only offsite copy";
      after = [
        "immich-server.service"
        "postgresql.service"
      ];
      requires = [ "postgresql.service" ];
      unitConfig.RequiresMountsFor = [ disk.mountPoint ];
      onFailure = [ "immich-backup-alert.service" ];
      # One process at a time: Proton refresh tokens are single-use, so two
      # concurrent rclone clients on one credential blank the session
      # (rclone#9880). systemd never runs two instances of a oneshot at once,
      # and copy/check are sequential within the single run.
      serviceConfig = {
        Type = "oneshot";
        User = "immich";
        Group = "immich";
        # tmpfiles creates this at boot, but a mid-session `switch` can run it
        # before the disk is mounted (the dir then lands on the shadowed root
        # fs). The `+` makes this run privileged, after RequiresMountsFor, so
        # the tenant folder always exists on the real disk.
        ExecStartPre = [
          "+${pkgs.coreutils}/bin/install -d -o immich -g immich -m 0700 ${disk.mountPoint}/immich"
        ];
        ExecStart = "${immich-backup}/bin/immich-backup ${args}";
        Environment = [ "HOME=/var/lib/immich" ];
        path = [
          pkgs.restic
          pkgs.rclone
          config.services.postgresql.package
        ];
      };
    };

    systemd.timers.immich-backup = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = bcfg.schedule;
        Persistent = true;
      };
    };

    # A failed or stalled backup must not be silent: leave a marker on the disk
    # and a journal error. A real notifier (ntfy/mail) is wired in T8.
    systemd.services.immich-backup-alert = {
      description = "Mark that the Immich backup failed";
      serviceConfig = {
        Type = "oneshot";
        ExecStartPre = [
          "+${pkgs.coreutils}/bin/mkdir -p ${disk.mountPoint}/immich"
        ];
        ExecStart = pkgs.writeShellScript "immich-backup-alert" ''
          echo "$(date -Is) immich backup FAILED; run: journalctl -u immich-backup" \
            >> ${disk.mountPoint}/immich/BACKUP-FAILED
          ${pkgs.systemd}/bin/systemd-cat -t immich-backup -p err \
            <<< "Immich backup FAILED"
        '';
      };
    };
  };
}
