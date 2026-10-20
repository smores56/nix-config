# Generic rclone 3-2-1 backup: one oneshot service + timer per
# backup.datasets.<Name>. Each run keeps a versioned local mirror
# (`copy` + `--backup-dir`) and, unless offsite is disabled, an append-only
# checksummed mirror to the remote. The rationale for copy-over-sync and the
# unchecked-hash guard lives in modules/features/backup/backup.sh.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.backup;

  # The driver is a self-contained shell script; writeShellApplication pins its
  # runtime tools on PATH, so the unit needs no implicit system PATH. It keeps
  # the same CLI flags the Python driver had, so ExecStart and the restore drill
  # read the same way.
  backup = pkgs.writeShellApplication {
    name = "backup";
    bashOptions = [ ];
    runtimeInputs = [
      pkgs.rclone
      pkgs.coreutils
      pkgs.jq
      pkgs.util-linux
      pkgs.findutils
      pkgs.bash
    ];
    text = builtins.readFile ../features/backup/backup.sh;
  };

  backup-watch = pkgs.writeShellApplication {
    name = "backup-watch";
    bashOptions = [ ];
    runtimeInputs = [
      pkgs.inotify-tools
      pkgs.coreutils
      pkgs.findutils
      pkgs.bash
    ];
    text = builtins.readFile ../features/backup/backup_watch.sh;
  };

  # The source default lives here once so the watcher and the driver agree.
  sourceOf =
    name: dataset: if dataset.source != null then dataset.source else "/var/lib/media/${name}";
  # The generated postgres pre-unit writes one dump per dataset here. The
  # backup unit copies it into the dataset's current/db and fails if it is
  # stale; keeping the dump outside the source tree means the unit needs no
  # write access to /var/backup and the postgres user never sees the mirror.
  pgDumpDir = "/var/lib/postgresql/backups";
  pgDumpFile = name: "${pgDumpDir}/${lib.toLower name}.dump";
  # systemd.path cannot watch recursively, so the watcher writes into this queue
  # and `DirectoryNotEmpty=` (re-checked after each run) starts the backup unit.
  queueDir = name: "/run/backup-watch/${lib.toLower name}";
  unitName = name: "backup-${lib.toLower name}";

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
    name: dataset: fullCheck:
    let
      source = sourceOf name dataset;
    in
    lib.concatStringsSep " " (
      [
        "--name ${lib.escapeShellArg name}"
        "--source ${lib.escapeShellArg source}"
        "--backup-root ${lib.escapeShellArg cfg.mountPoint}"
        "--remote ${lib.escapeShellArg cfg.remote}"
        "--rclone-config ${lib.escapeShellArg cfg.rcloneConfig}"
        "--stall-timeout ${lib.escapeShellArg dataset.stallTimeout}"
        "--timeout ${lib.escapeShellArg dataset.timeout}"
      ]
      ++ lib.optional fullCheck "--full-check"
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

  mkDumpService =
    name: dataset:
    let
      dump = pgDumpFile name;
      script = pkgs.writeShellScript "backup-${lib.toLower name}-dump" ''
        set -euo pipefail
        tmp=${lib.escapeShellArg (dump + ".tmp")}
        trap 'rm -f "$tmp"' EXIT
        ${config.services.postgresql.package}/bin/pg_dump -Fc --no-owner ${lib.escapeShellArg dataset.postgresDatabase} > "$tmp"
        mv "$tmp" ${lib.escapeShellArg dump}
      '';
    in
    {
      description = "Dump PostgreSQL (${dataset.postgresDatabase}) for ${name} backup";
      after = [ "postgresql.service" ];
      requires = [ "postgresql.service" ];
      # The backup unit copies the dump into current/db; keeping the dump out of
      # /var/backup means postgres needs write access only to its own directory.
      path = [
        pkgs.coreutils
        pkgs.bash
        config.services.postgresql.package
      ];
      serviceConfig = {
        Type = "oneshot";
        User = "postgres";
        Group = "postgres";
        ExecStart = script;
        TimeoutStartSec = "1h";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ pgDumpDir ];
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

  mkService =
    name: dataset: fullCheck:
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
      description = "rclone 3-2-1 backup: ${name}${lib.optionalString fullCheck " (full check)"}";
      unitConfig.RequiresMountsFor = [ cfg.mountPoint ];
      # Only a dataset whose preBackup dumps Postgres needs the server (and must
      # not race a DB restart at boot); a generic dataset must not depend on it.
      after =
        lib.optional dataset.postgres "postgresql.service"
        ++ lib.optional dataset.postgres "${unitName name}-dump.service";
      # Start the dump unit with this run and fail the run if the dump fails.
      requires = lib.optional dataset.postgres "${unitName name}-dump.service";
      # The Cloudflare email template is the alert path; reference it only when
      # enabled, or systemd logs a dead-job error.
      onFailure = lib.optional config.alerting.enable "cloudflare-email@%n.service";
      # Put rclone on the unit's PATH. This must be the service attribute (not
      # serviceConfig.path, which systemd renders verbatim as an ignored `path=`
      # directive and leaves the default PATH without it). The driver wrapper
      # already carries its own runtime tools; rclone stays here for ops and the
      # restore drill, which run it directly.
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
        # The preBackup step processes repo-controlled content (ghorg/git) as
        # root, so contain it where it is safe for every dataset. ProtectSystem
        # is deliberately absent: each dataset would need its own ReadWritePaths.
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        RestrictSUIDSGID = true;
        RestrictRealtime = true;
        LockPersonality = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        # Cap the wall-clock run: a seed copy can take hours, a stuck one must not.
        TimeoutStartSec = dataset.timeout;
        # The `+` runs this privileged, after RequiresMountsFor, so the dataset
        # folders always exist on the real disk even on a mid-session `switch`.
        # A watched dataset drains its request queue here: changes that arrive
        # during the run create new requests, and the path unit re-checks the
        # directory when the service exits (one follow-up run, never a loss).
        ExecStartPre = [
          "+${pkgs.coreutils}/bin/install -d -m 0700 ${lib.escapeShellArg dir} ${
            lib.escapeShellArg (dir + "/current")
          } ${lib.escapeShellArg (dir + "/versions")}"
        ]
        ++ lib.optional dataset.onChange.enable "+${pkgs.findutils}/bin/find ${lib.escapeShellArg (queueDir name)} -mindepth 1 -delete";
        # Every dataset shares one Proton credential, and Proton refresh tokens
        # are single-use: two concurrent rclone clients blank the session
        # (rclone#9880). The driver owns the host-wide lock at
        # /run/lock/media-backup.lock (created mode 0600) and serializes inside
        # itself, so the unit must not wrap ExecStart in its own flock.
        ExecStart = "${backup}/bin/backup ${mkArgs name dataset fullCheck}";
        ExecStopPost = [ stopPost ];
      };
    };

  # Long-running watcher for one dataset. It only reads the source and writes
  # request files; the path unit below starts the real backup service.
  mkWatchService = name: dataset: {
    description = "Queue a ${name} backup after source changes";
    wantedBy = [ "multi-user.target" ];
    # A missing source must skip the unit, not restart-loop it.
    unitConfig.ConditionPathIsDirectory = sourceOf name dataset;
    # The helper spawns `inotifywait`; the service attribute is the only PATH
    # that survives systemd rendering (see the driver service above).
    path = [ pkgs.inotify-tools ];
    serviceConfig = {
      Type = "simple";
      User = "root";
      ExecStart = lib.escapeShellArgs (
        [
          "${backup-watch}/bin/backup-watch"
          "--source"
          (sourceOf name dataset)
          "--queue-dir"
          (queueDir name)
          "--debounce-seconds"
          (toString (parseDurationSeconds dataset.onChange.debounce))
        ]
        ++ lib.concatMap (pattern: [
          "--ignore"
          pattern
        ]) dataset.onChange.ignore
      );
      Restart = "always";
      RestartSec = "10s";
      # Reads the source, writes only its queue; no network access is needed.
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ReadWritePaths = [ (queueDir name) ];
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      ProtectClock = true;
      ProtectHostname = true;
      RestrictSUIDSGID = true;
      RestrictRealtime = true;
      LockPersonality = true;
      RestrictAddressFamilies = [ "AF_UNIX" ];
    };
  };

  mkTimer = calendar: {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = calendar;
      Persistent = true;
    };
  };
in
{
  config = lib.mkIf (cfg.datasets != { }) {
    assertions = [
      {
        assertion = cfg.enable;
        message = "backup.datasets requires backup (the backup disk) to be enabled.";
      }
    ]
    ++ lib.mapAttrsToList (name: dataset: {
      assertion = !dataset.postgres || dataset.preBackup != null;
      message = "backup.datasets.${name}.postgres requires a preBackup snippet that copies ${pgDumpFile name} into BACKUP_CURRENT/db.";
    }) cfg.datasets
    ++ lib.mapAttrsToList (name: dataset: {
      # cadences can trip on a slow-but-alive transfer. "0" disables the watchdog.
      # parseDurationSeconds accepts a far broader grammar (words, compounds,
      # spaces) than the driver's parse_duration (`\d+[smhd]?`), so guard the
      # grammar too: a value like "1min" would pass eval then crash every run.
      assertion =
        let
          seconds = parseDurationSeconds dataset.stallTimeout;
        in
        dataset.stallTimeout == "0"
        || (
          builtins.match "[0-9]+[smhd]?" dataset.stallTimeout != null && seconds != null && seconds >= 60
        );
      message = "backup.datasets.${name}.stallTimeout must be \"0\" (disabled) or \"<number><s|m|h|d>\" of at least 60s (two rclone 30s stats intervals), got \"${dataset.stallTimeout}\".";
    }) cfg.datasets
    ++ lib.mapAttrsToList (name: dataset: {
      assertion = dataset.fullCheckSchedule == null || dataset.fullCheckSchedule != "";
      message = "backup.datasets.${name}.fullCheckSchedule must be null (disabled) or a non-empty systemd OnCalendar expression, got \"${dataset.fullCheckSchedule}\".";
    }) cfg.datasets
    ++ lib.mapAttrsToList (name: dataset: {
      # The watcher parses the same compact grammar as the driver's timeout.
      assertion =
        !dataset.onChange.enable
        || (
          builtins.match "[0-9]+[smhd]?" dataset.onChange.debounce != null
          && parseDurationSeconds dataset.onChange.debounce != null
          && parseDurationSeconds dataset.onChange.debounce >= 1
        );
      message = "backup.datasets.${name}.onChange.debounce must be \"<number><s|m|h|d>\" of at least 1s, got \"${dataset.onChange.debounce}\".";
    }) cfg.datasets;

    # The driver creates the host-wide lock itself; this only guarantees it
    # exists at mode 0600 (root-only) and never widens it. Each watched dataset
    # gets a root-only queue directory for the watcher's request files.
    systemd.tmpfiles.rules = [
      "f /run/lock/media-backup.lock 0600 root root -"
    ]
    ++ lib.optional (lib.any (dataset: dataset.postgres) (
      lib.attrValues cfg.datasets
    )) "d ${pgDumpDir} 0700 postgres postgres -"
    ++ lib.mapAttrsToList (name: _: "d ${queueDir name} 0700 root root -") (
      lib.filterAttrs (_: dataset: dataset.onChange.enable) cfg.datasets
    );

    # rclone for ops/restore (the restore drill runs it as root); `backup` for
    # manual/seed runs.
    environment.systemPackages = [
      backup
      pkgs.rclone
    ];

    systemd.services =
      lib.mapAttrs' (
        name: dataset: lib.nameValuePair (unitName name) (mkService name dataset false)
      ) cfg.datasets
      // lib.mapAttrs' (
        name: dataset: lib.nameValuePair "${unitName name}-fullcheck" (mkService name dataset true)
      ) (lib.filterAttrs (_: dataset: dataset.fullCheckSchedule != null) cfg.datasets)
      // lib.mapAttrs' (
        name: dataset: lib.nameValuePair "${unitName name}-watch" (mkWatchService name dataset)
      ) (lib.filterAttrs (_: dataset: dataset.onChange.enable) cfg.datasets)
      // lib.mapAttrs' (
        name: dataset: lib.nameValuePair "${unitName name}-dump" (mkDumpService name dataset)
      ) (lib.filterAttrs (_: dataset: dataset.postgres) cfg.datasets);

    # DirectoryNotEmpty is re-checked after the backup service exits, so a
    # change during a run leaves a request behind and triggers exactly one more
    # run (PathChanged would silently lose it).
    systemd.paths = lib.mapAttrs' (
      name: _:
      lib.nameValuePair "${unitName name}-queue" {
        wantedBy = [ "paths.target" ];
        pathConfig = {
          DirectoryNotEmpty = queueDir name;
          Unit = "${unitName name}.service";
        };
      }
    ) (lib.filterAttrs (_: dataset: dataset.onChange.enable) cfg.datasets);

    systemd.timers =
      lib.mapAttrs' (
        name: dataset: lib.nameValuePair (unitName name) (mkTimer dataset.schedule)
      ) cfg.datasets
      // lib.mapAttrs' (
        name: dataset: lib.nameValuePair "${unitName name}-fullcheck" (mkTimer dataset.fullCheckSchedule)
      ) (lib.filterAttrs (_: dataset: dataset.fullCheckSchedule != null) cfg.datasets);
  };
}
