# restic-backed datasets: one local repository per dataset plus an append-only
# byte copy of that repository on the Proton remote. restic owns dedup,
# encryption, snapshots, retention and check; resticprofile owns the backup
# command and the post-run hooks; the module owns the systemd units, the host
# lock and the alert markers.
#
# Why a byte copy instead of restic's rclone backend: Proton's rclone backend
# is Tier 4/Experimental, its refresh tokens are single-use, and a live restic
# repository multiplies the small-object churn where Proton fails. Copying the
# finished repository keeps Proton as dumb storage and leaves a portable repo
# format behind.
#
# The old rclone datasets stay in backup-datasets.nix until their own
# migration (T12). Both drivers share /run/lock/media-backup.lock, the
# BACKUP-FAILED/BACKUP-LAST-SUCCESS markers and the backup-<name> unit names,
# so the existing freshness alert and operator commands keep working.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.backup;

  resticDatasets = lib.filterAttrs (_: dataset: dataset.driver == "restic") cfg.datasets;

  # nixpkgs resticprofile 0.31.0 fails checkPhase in its Go test suite. The
  # binary itself builds and passed the T2 spike; keep the tests off rather
  # than shipping a package that cannot be built, and revisit when upstream
  # (or nixpkgs) fixes the failing tests.
  resticprofile = pkgs.resticprofile.overrideAttrs (_: {
    doCheck = false;
  });

  lower = name: lib.toLower name;
  unitName = name: "backup-${lower name}";
  sourceOf =
    name: dataset: if dataset.source != null then dataset.source else "/var/lib/media/${name}";
  repoOf =
    name: dataset:
    if dataset.repository != null then dataset.repository else "${cfg.mountPoint}/restic/${name}";
  protonPathOf =
    name: dataset: if dataset.protonPath != null then dataset.protonPath else "restic/${name}";
  markerDir = name: "${cfg.mountPoint}/${name}";
  stagingDir = name: "/var/lib/restic-staging/${lower name}";
  queueDir = name: "/run/backup-watch/${lower name}";
  # Deliberately outside queueDir: a persistent marker inside the directory the
  # path unit watches would keep DirectoryNotEmpty true forever.
  runningFile = name: "/run/backup-watch/${lower name}.running";
  cacheDir = "/var/cache/restic";
  lockPath = "/run/lock/media-backup.lock";

  backup-watch = pkgs.writeShellScriptBin "backup-watch" ''
    exec ${pkgs.bash}/bin/bash ${../features/backup/backup_watch.sh} "$@"
  '';
  successMarker = name: "${markerDir name}/BACKUP-LAST-SUCCESS";
  failedMarker = name: "${markerDir name}/BACKUP-FAILED";

  # onChange.debounce shares the compact grammar enforced for the rclone
  # driver; convert it to the whole seconds the shell watcher takes.
  parseDebounceSeconds =
    value:
    let
      match = builtins.match "([0-9]+)([smhd]?)" value;
      multiplier = {
        "" = 1;
        s = 1;
        m = 60;
        h = 3600;
        d = 86400;
      };
    in
    if match == null then
      null
    else
      builtins.fromJSON (builtins.elemAt match 0) * multiplier.${builtins.elemAt match 1};

  # TOML basic string. Paths and patterns never contain quotes in practice,
  # but escaping keeps a future odd source path from breaking the config.
  tomlString = value: "\"${lib.replaceStrings [ "\\" "\"" ] [ "\\\\" "\\\"" ] value}\"";
  tomlArray = values: "[" + lib.concatMapStringsSep ", " tomlString values + "]";
  tomlList = values: "[ " + lib.concatMapStringsSep ", " tomlString values + " ]";

  pwFile = dataset: dataset.passwordFile;
  repo = name: dataset: repoOf name dataset;

  mkProfile =
    name: dataset:
    let
      profile = lower name;
      top = lib.concatMapStringsSep "\n" (line: "  ${line}") [
        "repository = ${tomlString (repo name dataset)}"
        "password-file = ${tomlString (pwFile dataset)}"
        "cache-dir = ${tomlString cacheDir}"
        "initialize = true"
      ];
      backupSources = [ (sourceOf name dataset) ] ++ lib.optional dataset.postgres (stagingDir name);
      backupLines = [
        "source = ${tomlList backupSources}"
        "tag = ${tomlList [ profile ]}"
        "one-file-system = true"
        "exclude = ${tomlList dataset.excludes}"
        "run-after = ${tomlArray (mkAfterHooks name dataset)}"
        "run-after-fail = ${tomlArray (mkFailHooks name dataset)}"
      ];
      retentionLines = [
        "after-backup = true"
        "prune = true"
        "keep-daily = ${toString dataset.retention.daily}"
        "keep-weekly = ${toString dataset.retention.weekly}"
        "keep-monthly = ${toString dataset.retention.monthly}"
        "keep-yearly = ${toString dataset.retention.yearly}"
      ];
      checkLines = [ "read-data-subset = \"10%\"" ];
    in
    ''
      version = "1"

      [global]
        restic-binary = ${tomlString "${pkgs.restic}/bin/restic"}

      [${profile}]
      ${top}

        [${profile}.backup]
      ${lib.concatMapStringsSep "\n" (line: "    ${line}") backupLines}

        [${profile}.retention]
      ${lib.concatMapStringsSep "\n" (line: "    ${line}") retentionLines}
    ''
    + lib.optionalString dataset.check ''
        [${profile}.check]
      ${lib.concatMapStringsSep "\n" (line: "    ${line}") checkLines}
    '';

  # run-after only runs after a successful backup and retention, so the marker
  # means "backed up and verified locally". The check is an explicit restic
  # command rather than `check-after`: the check section carries the
  # read-data-subset used by the weekly full check, and check-after would apply
  # it on every nightly run (a 10% data read of the whole repository).
  mkAfterHooks =
    name: dataset:
    let
      restic = "${pkgs.restic}/bin/restic";
      rclone = "${pkgs.rclone}/bin/rclone";
      remote = "${cfg.remote}:${protonPathOf name dataset}";
      config = cfg.rcloneConfig;
      check = lib.optional dataset.check "${restic} --repo ${repo name dataset} --password-file ${pwFile dataset} check";
      copy = [
        "${rclone} --config ${config} --timeout 5m --contimeout 30s --retries 5 --low-level-retries 20 --retries-sleep 10s copy ${repo name dataset} ${remote} --transfers 8 --checkers 16 --protondrive-replace-existing-draft=true"
        "${rclone} --config ${config} --timeout 5m --contimeout 30s --retries 5 --low-level-retries 20 --retries-sleep 10s check ${repo name dataset} ${remote} --one-way --transfers 8 --checkers 16"
      ];
      markSuccess =
        "${pkgs.coreutils}/bin/date -Is > ${successMarker name}.tmp"
        + " && ${pkgs.coreutils}/bin/mv -f ${successMarker name}.tmp ${successMarker name}"
        + " && ${pkgs.coreutils}/bin/rm -f ${failedMarker name}";
    in
    check ++ (if dataset.offsite then copy else [ ]) ++ [ markSuccess ];

  mkFailHooks =
    name: _dataset:
    let
      writeFailed =
        "${pkgs.coreutils}/bin/date -Is > ${failedMarker name}.tmp"
        + " && ${pkgs.coreutils}/bin/mv -f ${failedMarker name}.tmp ${failedMarker name}";
    in
    [
      "${pkgs.coreutils}/bin/rm -f ${successMarker name}"
      writeFailed
    ];

  # A wall-clock timeout or a failed resticprofile lock skips run-after-fail,
  # so systemd writes the generic marker. A detailed marker from the hooks is
  # never overwritten.
  mkStopPost =
    name: _dataset:
    pkgs.writeShellScript "backup-${lower name}-stop-post" ''
      ${pkgs.coreutils}/bin/rm -f ${lib.escapeShellArg (runningFile name)}
      if [ -n "''${SERVICE_RESULT:-}" ] && [ "''${SERVICE_RESULT}" != success ]; then
        ${pkgs.coreutils}/bin/install -d -m 0700 ${lib.escapeShellArg (markerDir name)}
        if [ ! -e ${lib.escapeShellArg (failedMarker name)} ]; then
          printf '%s exit=%s\n' "$SERVICE_RESULT" "''${EXIT_CODE:-?}" > ${lib.escapeShellArg (failedMarker name)}
        fi
      fi
    '';
in
{
  config = lib.mkIf (resticDatasets != { }) {
    assertions = [
      {
        assertion = cfg.enable;
        message = "backup.datasets with driver = \"restic\" requires backup (the backup disk) to be enabled.";
      }
    ]
    ++ lib.mapAttrsToList (name: dataset: {
      assertion = !dataset.postgres || dataset.postgresDatabase != "";
      message = "backup.datasets.${name}.postgresDatabase must name the database to dump.";
    }) resticDatasets
    ++ lib.mapAttrsToList (name: dataset: {
      assertion = dataset.preBackup == null;
      message = "backup.datasets.${name}.preBackup is only run by the rclone driver; a restic dataset needs its own pre-unit (like backup-${lower name}-dump) instead.";
    }) resticDatasets
    ++ lib.mapAttrsToList (name: dataset: {
      assertion =
        !dataset.onChange.enable
        || (
          builtins.match "[0-9]+[smhd]?" dataset.onChange.debounce != null
          && parseDebounceSeconds dataset.onChange.debounce != null
          && parseDebounceSeconds dataset.onChange.debounce >= 1
        );
      message = "backup.datasets.${name}.onChange.debounce must be \"<number><s|m|h|d>\" of at least 1s, got \"${dataset.onChange.debounce}\".";
    }) resticDatasets
    ++ lib.mapAttrsToList (name: dataset: {
      assertion = dataset.check || !dataset.offsite;
      message = "backup.datasets.${name}: offsite restic datasets must keep check = true; the Proton copy is only valid after a local check.";
    }) resticDatasets;

    systemd.tmpfiles.rules =
      lib.mapAttrsToList (name: dataset: "d ${repoOf name dataset} 0700 root root -") resticDatasets
      ++ lib.mapAttrsToList (name: _: "d ${markerDir name} 0700 root root -") resticDatasets
      ++ lib.mapAttrsToList (name: _: "d ${stagingDir name} 0700 postgres postgres -") (
        lib.filterAttrs (_: dataset: dataset.postgres) resticDatasets
      )
      ++ lib.mapAttrsToList (name: _: "d ${queueDir name} 0700 root root -") (
        lib.filterAttrs (_: dataset: dataset.onChange.enable) resticDatasets
      )
      ++ [
        "d ${cacheDir} 0700 root root -"
        "d /run/backup-watch 0700 root root -"
      ];

    environment.systemPackages = [
      pkgs.restic
      resticprofile
      pkgs.rclone
    ];

    systemd.services =
      lib.mapAttrs' (
        name: dataset:
        lib.nameValuePair (unitName name) {
          description = "restic backup: ${name}";
          unitConfig.RequiresMountsFor = [ cfg.mountPoint ];
          after =
            lib.optional dataset.postgres "postgresql.service"
            ++ lib.optional dataset.postgres "${unitName name}-dump.service";
          requires = lib.optional dataset.postgres "${unitName name}-dump.service";
          onFailure = lib.optional config.alerting.enable "cloudflare-email@%n.service";
          path = [
            resticprofile
            pkgs.restic
            pkgs.rclone
            pkgs.coreutils
            pkgs.bash
            pkgs.util-linux
          ];
          environment = {
            # ProtectHome hides the real home; resticprofile only needs a
            # writable scratch place for its local lock. PrivateTmp supplies it.
            HOME = "/tmp";
          };
          serviceConfig = {
            Type = "oneshot";
            User = "root";
            # The repository, markers, and the flock file must not be readable
            # by unprivileged users; the Proton credential is shared.
            UMask = "0077";
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
            TimeoutStartSec = dataset.timeout;
            # `+` runs these as root before the sandboxed command, so the
            # repository and marker directories always exist after a late
            # mount. A watched dataset also drains its request queue here and
            # publishes the running marker the watcher uses to label follow-ups.
            ExecStartPre = [
              "+${pkgs.coreutils}/bin/install -d -m 0700 ${lib.escapeShellArg (repoOf name dataset)} ${lib.escapeShellArg (markerDir name)} ${lib.escapeShellArg cacheDir}"
            ]
            ++ lib.optional dataset.postgres "+${pkgs.coreutils}/bin/install -d -o postgres -g postgres -m 0700 ${lib.escapeShellArg (stagingDir name)}"
            ++ lib.optional dataset.onChange.enable "+${pkgs.coreutils}/bin/find ${lib.escapeShellArg (queueDir name)} -mindepth 1 -delete"
            ++ lib.optional dataset.onChange.enable "+${pkgs.coreutils}/bin/install -m 0600 /dev/null ${lib.escapeShellArg (runningFile name)}";
            # Probe refresh tokens are single-use and the Proton byte copy
            # shares one credential with the legacy rclone datasets: every
            # restic run holds the host-wide lock, so the copy and check are
            # serialized too.
            ExecStart = lib.concatStringsSep " " [
              "${pkgs.util-linux}/bin/flock"
              lockPath
              "${resticprofile}/bin/resticprofile"
              "--config ${lib.escapeShellArg (pkgs.writeText "backup-${lower name}-resticprofile.toml" (mkProfile name dataset))}"
              "--name ${lower name}"
              "backup"
            ];
            ExecStopPost = [ (mkStopPost name dataset) ];
          };
        }
      ) resticDatasets
      // lib.mapAttrs' (
        name: dataset:
        lib.nameValuePair "${unitName name}-fullcheck" {
          description = "restic check --read-data-subset: ${name}";
          unitConfig.RequiresMountsFor = [ cfg.mountPoint ];
          onFailure = lib.optional config.alerting.enable "cloudflare-email@%n.service";
          path = [
            resticprofile
            pkgs.restic
            pkgs.coreutils
            pkgs.bash
            pkgs.util-linux
          ];
          environment.HOME = "/tmp";
          serviceConfig = {
            Type = "oneshot";
            User = "root";
            # The repository, markers, and the flock file must not be readable
            # by unprivileged users; the Proton credential is shared.
            UMask = "0077";
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
            TimeoutStartSec = dataset.timeout;
            ExecStart = lib.concatStringsSep " " [
              "${pkgs.util-linux}/bin/flock"
              lockPath
              "${resticprofile}/bin/resticprofile"
              "--config ${lib.escapeShellArg (pkgs.writeText "backup-${lower name}-resticprofile.toml" (mkProfile name dataset))}"
              "--name ${lower name}"
              "check"
            ];
            ExecStopPost = [ (mkStopPost name dataset) ];
          };
        }
      ) (lib.filterAttrs (_: dataset: dataset.check && dataset.fullCheckSchedule != null) resticDatasets)
      // lib.mapAttrs' (
        name: dataset:
        lib.nameValuePair "${unitName name}-dump" {
          description = "Dump PostgreSQL (${dataset.postgresDatabase}) for ${name} restic backup";
          after = [ "postgresql.service" ];
          requires = [ "postgresql.service" ];
          path = [
            pkgs.coreutils
            pkgs.bash
            pkgs.gzip
            config.services.postgresql.package
          ];
          serviceConfig = {
            Type = "oneshot";
            User = "postgres";
            Group = "postgres";
            # The dump holds every secret in Immich's database; the staging
            # directory is 0700 postgres and only root reads it for restic.
            UMask = "0077";
            ExecStart = pkgs.writeShellScript "backup-${lower name}-dump" ''
              set -euo pipefail
              out=${lib.escapeShellArg "${stagingDir name}/${dataset.postgresDatabase}.sql.gz"}
              tmp="$out.tmp"
              trap 'rm -f "$tmp"' EXIT
              ${config.services.postgresql.package}/bin/pg_dump --clean --if-exists -d ${lib.escapeShellArg dataset.postgresDatabase} \
                | ${pkgs.gzip}/bin/gzip > "$tmp"
              mv "$tmp" "$out"
            '';
            TimeoutStartSec = "1h";
            NoNewPrivileges = true;
            PrivateTmp = true;
            ProtectHome = true;
            ProtectSystem = "strict";
            ReadWritePaths = [ (stagingDir name) ];
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
        }
      ) (lib.filterAttrs (_: dataset: dataset.postgres) resticDatasets)
      // lib.mapAttrs' (
        name: dataset:
        lib.nameValuePair "${unitName name}-watch" {
          description = "Queue a ${name} restic backup after source changes";
          wantedBy = [ "multi-user.target" ];
          unitConfig.ConditionPathIsDirectory = sourceOf name dataset;
          path = [
            pkgs.inotify-tools
            pkgs.coreutils
            pkgs.bash
          ];
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
                "--running-file"
                (runningFile name)
                "--debounce-seconds"
                (toString (parseDebounceSeconds dataset.onChange.debounce))
              ]
              ++ lib.concatMap (pattern: [
                "--ignore"
                pattern
              ]) dataset.onChange.ignore
            );
            Restart = "always";
            RestartSec = "10s";
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
        }
      ) (lib.filterAttrs (_: dataset: dataset.onChange.enable) resticDatasets);

    systemd.paths = lib.mapAttrs' (
      name: _:
      lib.nameValuePair "${unitName name}-queue" {
        wantedBy = [ "paths.target" ];
        pathConfig = {
          # DirectoryNotEmpty is re-checked when the service exits, so changes
          # during a run leave one follow-up request rather than losing it.
          DirectoryNotEmpty = queueDir name;
          Unit = "${unitName name}.service";
        };
      }
    ) (lib.filterAttrs (_: dataset: dataset.onChange.enable) resticDatasets);

    systemd.timers =
      lib.mapAttrs' (
        name: dataset:
        lib.nameValuePair (unitName name) {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = dataset.schedule;
            Persistent = true;
            RandomizedDelaySec = "15m";
          };
        }
      ) resticDatasets
      // lib.mapAttrs' (
        name: dataset:
        lib.nameValuePair "${unitName name}-fullcheck" {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = dataset.fullCheckSchedule;
            Persistent = true;
            RandomizedDelaySec = "15m";
          };
        }
      ) (lib.filterAttrs (_: dataset: dataset.check && dataset.fullCheckSchedule != null) resticDatasets);
  };
}
