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

  # Parse a systemd TimeSpan subset (space-separated <number><unit> tokens; a
  # unit-less token is seconds) into seconds, or null when unparseable. Only the
  # forms operators actually use are needed; anything else fails the assertion.
  parseDurationSeconds =
    value:
    let
      unitSeconds = {
        us = 0.000001;
        ms = 0.001;
        s = 1;
        sec = 1;
        second = 1;
        seconds = 1;
        m = 60;
        min = 60;
        minute = 60;
        minutes = 60;
        h = 3600;
        hr = 3600;
        hour = 3600;
        hours = 3600;
        d = 86400;
        day = 86400;
        days = 86400;
        w = 604800;
        week = 604800;
        weeks = 604800;
      };
      parseToken =
        token:
        let
          match = builtins.match "([0-9]+)([a-zA-Z]+)?" token;
        in
        if match == null then
          null
        else
          let
            amount = builtins.fromJSON (builtins.elemAt match 0);
            unit =
              if builtins.length match > 1 && builtins.elemAt match 1 != null then
                builtins.elemAt match 1
              else
                "s";
          in
          if unitSeconds ? ${unit} then amount * unitSeconds.${unit} else null;
      tokens = builtins.filter (token: token != "") (
        lib.splitString " " (builtins.replaceStrings [ "\t" ] [ " " ] value)
      );
      parts = map parseToken tokens;
    in
    if tokens == [ ] || lib.any (part: part == null) parts then
      null
    else
      lib.foldl' (total: part: total + part) 0 parts;

  mkArgs =
    name: dataset:
    let
      source = if dataset.source != null then dataset.source else "/var/lib/media/${name}";
    in
    lib.concatStringsSep " " (
      [
        "--name ${lib.escapeShellArg name}"
        "--source ${lib.escapeShellArg source}"
        "--backup-root ${lib.escapeShellArg cfg.mountPoint}"
        "--remote ${lib.escapeShellArg cfg.remote}"
        "--rclone-config ${lib.escapeShellArg cfg.rcloneConfig}"
        "--stall-timeout ${lib.escapeShellArg dataset.stallTimeout}"
      ]
      ++ lib.optional dataset.offsite "--offsite"
      # Materialised as a script file: a multi-line snippet cannot be a single
      # systemd ExecStart argument (newlines terminate the directive). Built only
      # when set, so a null preBackup never forces writeShellScript.
      ++ (
        if dataset.preBackup == null then
          [ ]
        else
          [
            "--pre-backup ${lib.escapeShellArg (pkgs.writeShellScript "backup-${lib.toLower name}-pre" dataset.preBackup)}"
          ]
      )
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
          # The in-process marker (driver) carries the real error; only fall back
          # to a generic one when the run was killed before that could run.
          if [ ! -e ${lib.escapeShellArg marker} ]; then
            printf '%s exit=%s\n' "$SERVICE_RESULT" "''${EXIT_CODE:-?}" > ${lib.escapeShellArg marker}
          fi
        fi
      '';
    in
    {
      description = "rclone 3-2-1 backup: ${name}";
      unitConfig.RequiresMountsFor = [ cfg.mountPoint ];
      # Only a dataset whose preBackup dumps Postgres needs the server (and must
      # not race a DB restart at boot); a generic dataset must not depend on it.
      after = lib.optional dataset.postgres "postgresql.service";
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
      ]
      ++ lib.optional dataset.postgres config.services.postgresql.package;
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
        # (rclone#9880). The driver owns the host-wide lock at
        # /run/lock/media-backup.lock (created mode 0600) and serializes inside
        # itself, so the unit must not wrap ExecStart in its own flock.
        ExecStart = "${backup}/bin/backup ${mkArgs name dataset}";
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
    ]
    ++ lib.mapAttrsToList (name: dataset: {
      # The driver's rclone stats cadence is 30s; a stall budget below two
      # cadences can trip on a slow-but-alive transfer. "0" disables the watchdog.
      assertion =
        let
          seconds = parseDurationSeconds dataset.stallTimeout;
        in
        dataset.stallTimeout == "0" || (seconds != null && seconds >= 60);
      message = "dotfiles.backup.datasets.${name}.stallTimeout must be \"0\" (disabled) or at least 60s (two rclone 30s stats intervals), got \"${dataset.stallTimeout}\".";
    }) cfg.datasets;

    # The driver creates the host-wide lock itself; this only guarantees it
    # exists at mode 0600 (root-only) and never widens it.
    systemd.tmpfiles.rules = [
      "f /run/lock/media-backup.lock 0600 root root -"
    ];

    # rclone for ops/restore (the restore drill runs it as root); `backup` for
    # manual/seed runs.
    environment.systemPackages = [
      backup
      pkgs.rclone
    ];

    systemd.services = lib.mapAttrs' (
      name: dataset: lib.nameValuePair "backup-${lib.toLower name}" (mkService name dataset)
    ) cfg.datasets;

    systemd.timers = lib.mapAttrs' (
      name: dataset: lib.nameValuePair "backup-${lib.toLower name}" (mkTimer name dataset)
    ) cfg.datasets;
  };
}
