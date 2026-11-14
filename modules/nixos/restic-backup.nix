# restic is the backup driver: one encrypted repo offsite in R2 and one on the
# local backup disk. A single job covers the durable tree and every
# source is encrypted client-side.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  hardening = import ../lib/hardening.nix;
  vmLib = import ../lib/agent-vm.nix { inherit pkgs lib; };

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

  assistantState = vmLib.assistantState user;
  # Letta's MemFS, transcripts and provider record; a sibling of the nanobot tree.
  lettaState = "/home/${user}/.local/state/letta";
  user = config.machine.username;
  home = "/home/${user}";
  # After the #509 cutover the agent VM and its state are gone, so restic must not
  # try to dump or walk them.
  cutover = config.kanbeiSplit.cutover.enable or false;

  # The sessions database lives on the virtiofs share, and only the guest may
  # open it: a host process bypasses the guest's WAL locks and breaks the live
  # connection. The guest wrapper dumps consistent copies into `backup/`; the
  # host only snapshots those.
  assistantDump = "${vmLib.launcher user}/bin/agent-sandbox agent-assistant dump";

  common = {
    paths = [
      "/var/lib/data"
    ]
    # The assistant's sessions, workspace and pairing; its logs, run files,
    # live databases, WebUI token and re-pairable gh config are excluded.
    ++ lib.optionals (!cutover) [
      assistantState
      # Letta's state is JSONL and git, which restic reads directly: no dump step and
      # no excludes, unlike the SQLite sessions above.
      lettaState
    ];
    exclude =
      lib.optionals (!cutover) [
        "${assistantState}/home/.nanobot/logs"
        "${assistantState}/home/.nanobot/run"
        "${assistantState}/home/.nanobot/media"
        "${assistantState}/home/.nanobot/llm_usage.sqlite3*"
        "${assistantState}/home/.nanobot/sessions/*/sessions.sqlite3*"
        "${assistantState}/home/.nanobot/sessions/sessions.sqlite3*"
        "${assistantState}/home/.nanobot/web-token"
        "${assistantState}/gh"
      ]
      # The memory wrapper's live SQLite now lives on the graphiti share; a host-side
      # walk copies a torn WAL set. The consistent artefact is the cluster's nightly
      # export under `graphiti/db-dumps`, which restic picks up with the share.
      ++ [
        "/var/lib/data/graphiti/memory/registry.sqlite*"
      ];
    # A missing state tree (the user removed it) must not fail the whole backup.
    # The dump runs in the guest; a failure keeps the previous copy and still
    # backs up the durable tree.
    backupPrepareCommand = lib.optionalString (!cutover) ''
      ${pkgs.coreutils}/bin/install -d -m 0700 -o ${user} -g users ${lib.escapeShellArg assistantState}
      cd ${lib.escapeShellArg home}
      ${pkgs.util-linux}/bin/runuser -u ${user} -- ${pkgs.coreutils}/bin/env HOME=${lib.escapeShellArg home} \
        ${assistantDump} \
        || echo "restic: the assistant dump failed; snapshotted the previous copy" >&2
    '';
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
      repository = "s3:https://${config.alerting.accountId}.r2.cloudflarestorage.com/restic-backup";
      environmentFile = config.sops.templates."restic-r2.env".path;
      # Only R2 initialises itself (a fresh bucket is expected). The local repo must not:
      # an empty-but-mounted /var/backup (wrong disk) would initialise a new repo and
      # report success. Unset, the first run fails and the alert fires; the operator
      # creates it by hand (modules/features/backup/README.md).
      initialize = true;
    };
    local = common // {
      repository = "/var/backup/restic";
    };
  };

  # The host database exists only while the native Immich runs; the cluster
  # backs up its own copy from the dump CronJob (#509).
  systemd.tmpfiles.rules = lib.mkIf config.services.postgresql.enable [
    "d ${dbDir} 0700 postgres postgres -"
  ];

  systemd.services.restic-db-dump = lib.mkIf config.services.postgresql.enable {
    description = "Dump the Immich database into the durable tree";
    after = [ "postgresql.service" ];
    requires = [ "postgresql.service" ];
    path = [ pkgs.coreutils ];
    onFailure = [ "ntfy-publish@%n.service" ];
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

  # The restic module exposes no `onFailure`, so the alert is attached to the generated
  # units by name; %n mails each repo's own journal. `wants` not `requires`: a down
  # database still lets the tree back up.
  systemd.services."restic-backups-r2" = {
    onFailure = [ "ntfy-publish@%n.service" ];
    wants = lib.optional config.services.postgresql.enable "restic-db-dump.service";
    after = lib.optional config.services.postgresql.enable "restic-db-dump.service";
  };

  # The local repo lives on the backup disk: wait for that mount, or a missing
  # disk would quietly fill the root filesystem instead of failing.
  systemd.services."restic-backups-local" = {
    onFailure = [ "ntfy-publish@%n.service" ];
    unitConfig.RequiresMountsFor = [ "/var/backup" ];
    wants = lib.optional config.services.postgresql.enable "restic-db-dump.service";
    after = lib.optional config.services.postgresql.enable "restic-db-dump.service";
  };
}
