# Generic rclone 3-2-1 backup: one oneshot service + timer per
# dotfiles.backup.datasets.<Name>. Each run keeps a versioned local mirror
# (`copy` + `--backup-dir`) and, unless offsite is disabled, an append-only
# checksummed mirror to the remote. The rationale for copy-over-sync and the
# unchecked-hash guard lives in modules/features/backup/backup.py.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles.backup;

  backup = pkgs.writeShellScriptBin "backup" ''
    exec ${pkgs.python3}/bin/python3 ${./../features/backup/backup.py} "$@"
  '';

  mkArgs =
    name: dataset:
    let
      source = if dataset.source != null then dataset.source else "/var/lib/media/${name}";
      # Materialised as a script file: a multi-line snippet cannot be a single
      # systemd ExecStart argument (newlines terminate the directive).
      pre = pkgs.writeShellScript "backup-${lib.toLower name}-pre" dataset.preBackup;
    in
    lib.concatStringsSep " " (
      [
        "--name ${lib.escapeShellArg name}"
        "--source ${lib.escapeShellArg source}"
        "--backup-root ${lib.escapeShellArg cfg.mountPoint}"
        "--remote ${lib.escapeShellArg cfg.remote}"
        "--rclone-config ${lib.escapeShellArg cfg.rcloneConfig}"
      ]
      ++ lib.optional dataset.offsite "--offsite"
      ++ lib.optional (dataset.preBackup != null) "--pre-backup ${lib.escapeShellArg pre}"
      ++ lib.concatMap (pattern: [
        "--exclude"
        (lib.escapeShellArg pattern)
      ]) dataset.excludes
    );

  mkService =
    name: dataset:
    let
      dir = "${cfg.mountPoint}/${name}";
      marker = "${dir}/BACKUP-FAILED";
      # A wall-clock timeout SIGTERMs the run, so the in-process marker never
      # executes; systemd reports why the unit stopped via SERVICE_RESULT.
      stopPost = pkgs.writeShellScript "backup-failed-marker" ''
        if [ -n "''${SERVICE_RESULT:-}" ] && [ "''${SERVICE_RESULT}" != success ]; then
          ${pkgs.coreutils}/bin/install -d -m 0700 ${lib.escapeShellArg dir}
          printf '%s exit=%s\n' "$SERVICE_RESULT" "''${EXIT_CODE:-?}" > ${lib.escapeShellArg marker}
        fi
      '';
    in
    {
      description = "rclone 3-2-1 backup: ${name}";
      unitConfig.RequiresMountsFor = [ cfg.mountPoint ];
      # A preBackup that dumps Postgres must not race a DB restart at boot.
      after = lib.optional (dataset.preBackup != null) "postgresql.service";
      # Only reference the handler when notify is enabled; otherwise the template
      # unit does not exist and a failure logs a dead-job error instead of a push.
      onFailure = lib.optional config.dotfiles.notify.enable config.dotfiles.notify.unit;
      # Put rclone on the unit's PATH. This must be the service attribute (not
      # serviceConfig.path, which systemd renders verbatim as an ignored `path=`
      # directive and leaves the default PATH without it).
      path = [
        pkgs.rclone
        pkgs.coreutils
        pkgs.bash
        pkgs.util-linux
        config.services.postgresql.package
      ];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        # Cap the wall-clock run: a seed copy can take hours, a stuck one must not.
        TimeoutStartSec = dataset.timeout;
        # The `+` runs this privileged, after RequiresMountsFor, so the dataset
        # folders always exist on the real disk even on a mid-session `switch`.
        ExecStartPre = [
          "+${pkgs.coreutils}/bin/install -d -m 0700 ${lib.escapeShellArg dir} ${
            lib.escapeShellArg (dir + "/current")
          } ${lib.escapeShellArg (dir + "/versions")}"
        ];
        # Every dataset shares one Proton credential, and Proton refresh tokens
        # are single-use: two concurrent rclone clients blank the session
        # (rclone#9880). Serialize on a host-wide lock.
        ExecStart = "${pkgs.util-linux}/bin/flock /run/lock/media-backup.lock ${backup}/bin/backup ${mkArgs name dataset}";
        ExecStopPost = [ stopPost ];
      };
    };

  mkTimer = _name: dataset: {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = dataset.schedule;
      Persistent = true;
    };
  };
in
{
  config = lib.mkIf (cfg.datasets != { }) {
    assertions = [
      {
        assertion = cfg.enable;
        message = "dotfiles.backup.datasets requires dotfiles.backup (the backup disk) to be enabled.";
      }
    ];

    environment.systemPackages = [ backup ];

    systemd.services = lib.mapAttrs' (
      name: dataset: lib.nameValuePair "backup-${lib.toLower name}" (mkService name dataset)
    ) cfg.datasets;

    systemd.timers = lib.mapAttrs' (
      name: dataset: lib.nameValuePair "backup-${lib.toLower name}" (mkTimer name dataset)
    ) cfg.datasets;
  };
}
