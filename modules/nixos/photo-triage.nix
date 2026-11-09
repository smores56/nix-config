# Local photo triage: a dedicated system user, a fixed data root, an Immich relay,
# a Unix-socket scoring server, and a scorer with no IP stack. T5 adds the run.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  ports = import ../ports.nix;
  cfg = config.photoTriage;
  hardening = import ../lib/hardening.nix;
  models = import ../lib/llama-cpp-models.nix { inherit pkgs; };

  user = "photo-triage";
  group = user;
  dataDir = "/var/lib/photo-triage";
  runtimeDir = "/run/photo-triage";
  albumRuntimeDir = "/run/photo-triage-album";
  maintenance = "${runtimeDir}/maintenance";
  immichSocket = "${runtimeDir}/immich.sock";
  immichAlbumSocket = "${albumRuntimeDir}/immich.sock";
  llmSocket = "${runtimeDir}/llm.sock";
  immichUpstream = "127.0.0.1:${toString ports.immich}";

  # The shared sandbox is the minimum; every unit adds its own deltas.
  base = hardening // {
    UMask = "0077";
    LimitCORE = 0;
    CapabilityBoundingSet = [ "" ];
    PrivateDevices = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectControlGroups = true;
    LockPersonality = true;
    RestrictSUIDSGID = true;
    SystemCallArchitectures = "native";
    SystemCallFilter = [ "@system-service" ];
  };

  # sudo drops the caller's environment, so the operator wrapper carries the
  # service paths itself instead of hard-coding them in Python.
  adminRun = pkgs.writeShellScript "photo-triage-admin-run" ''
    export PHOTO_TRIAGE_DATA_DIR=${dataDir}
    export PHOTO_TRIAGE_IMMICH_SOCKET=${immichSocket}
    export PHOTO_TRIAGE_IMMICH_ALBUM_SOCKET=${immichAlbumSocket}
    export PHOTO_TRIAGE_LLM_SOCKET=${llmSocket}
    export PHOTO_TRIAGE_MODEL=${models.modelAlias}
    export PHOTO_TRIAGE_MODEL_ID=${models.mainModelHash}
    export PHOTO_TRIAGE_MMPROJ_SHA256=${models.mmprojHash}
    exec ${cfg.package}/bin/photo-triage "$@"
  '';
  albumsRun = pkgs.writeShellScript "photo-triage-albums-run" ''
    export PHOTO_TRIAGE_DATA_DIR=${dataDir}
    export PHOTO_TRIAGE_IMMICH_ALBUM_SOCKET=${immichAlbumSocket}
    exec ${cfg.package}/bin/photo-triage albums "$@"
  '';
  calibrationRun = pkgs.writeShellScript "photo-triage-calibration-run" ''
    export PHOTO_TRIAGE_DATA_DIR=${dataDir}
    export PHOTO_TRIAGE_IMMICH_ALBUM_SOCKET=${immichAlbumSocket}
    exec ${cfg.package}/bin/photo-triage calibration "$@"
  '';
  # Transient units run the CLI as the service user with only the Unix sockets
  # and the data root reachable.
  transientProperties = [
    "--uid=${user}"
    "--gid=${group}"
    "--property=WorkingDirectory=${dataDir}"
    "--property=NoNewPrivileges=yes"
    "--property=PrivateTmp=yes"
    "--property=ProtectSystem=strict"
    "--property=ReadWritePaths=${dataDir} ${runtimeDir}"
    "--property=RestrictAddressFamilies=AF_UNIX"
    "--property=CapabilityBoundingSet="
  ];
  admin = pkgs.writeShellScriptBin "photo-triage-admin" (
    if cfg.readKeyFile == null then
      ''
        exec /run/wrappers/bin/sudo -u ${user} -- ${adminRun} "$@"
      ''
    else
      ''
        exec /run/wrappers/bin/sudo ${pkgs.systemd}/bin/systemd-run --quiet --pipe --wait --collect \
          ${lib.escapeShellArgs transientProperties} \
          '--property=LoadCredential=immich-read-key:${cfg.readKeyFile}' \
          -- ${adminRun} "$@"
      ''
  );
  # The album key never reaches the scorer unit. systemd-run supplies the key
  # through LoadCredential, so it is neither in the environment nor in argv.
  albumsAdmin = pkgs.writeShellScriptBin "photo-triage-albums" (
    if cfg.albumKeyFile == null then
      ''
        exec /run/wrappers/bin/sudo -u ${user} -- ${albumsRun} "$@"
      ''
    else
      ''
        exec /run/wrappers/bin/sudo ${pkgs.systemd}/bin/systemd-run --quiet --pipe --wait --collect \
          ${lib.escapeShellArgs transientProperties} \
          '--property=LoadCredential=immich-album-key:${cfg.albumKeyFile}' \
          -- ${albumsRun} "$@"
      ''
  );
  calibrationAdmin = pkgs.writeShellScriptBin "photo-triage-calibration" ''
    exec /run/wrappers/bin/sudo -u ${user} -- ${calibrationRun} "$@"
  '';
  # Only the sample publisher receives the album key; labels and reports run
  # with no Immich credential at all.
  calibrationPublishAdmin = pkgs.writeShellScriptBin "photo-triage-calibration-publish" (
    if cfg.albumKeyFile == null then
      ''
        exec /run/wrappers/bin/sudo -u ${user} -- ${calibrationRun} sample "$@"
      ''
    else
      ''
        exec /run/wrappers/bin/sudo ${pkgs.systemd}/bin/systemd-run --quiet --pipe --wait --collect \
          ${lib.escapeShellArgs transientProperties} \
          '--property=LoadCredential=immich-album-key:${cfg.albumKeyFile}' \
          -- ${calibrationRun} sample "$@"
      ''
  );

  # Idempotent teardown shared by the maintenance unit and the failure handler.
  windowStop = pkgs.writeShellScript "photo-triage-window-stop" ''
    ${pkgs.systemd}/bin/systemctl stop llama-cpp-photo-triage.service || true
    ${pkgs.coreutils}/bin/rm -f ${maintenance}
    ${pkgs.systemd}/bin/systemctl start --no-block llama-cpp.service || true
  '';

  scoringSettings = models.commonSettings // {
    host = llmSocket;
    alias = models.modelAlias;
    model = models.mainModel;
    ctx-size = 8192;
    no-cont-batching = true;
    reasoning = "off";
    no-webui = true;
    cors-origins = "localhost";
    log-verbosity = 1;
    temp = 0;
    top-k = 1;
    top-p = 1;
    min-p = 0;
    repeat-penalty = 1;
    seed = 42;
  };
  scoringExec = toString [
    (lib.getExe' models.llama-cpp "llama-server")
    (lib.cli.toCommandLine (optionName: {
      option = if builtins.stringLength optionName > 1 then "--${optionName}" else "-${optionName}";
      sep = " ";
      explicitBool = false;
      formatArg = lib.generators.mkValueStringDefault { };
    }) scoringSettings)
  ];

  mkRelay =
    {
      description,
      socket,
      upstream,
      directory ? runtimeDir,
      after ? [ ],
    }:
    {
      inherit description;
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-tmpfiles-setup.service" ] ++ after;
      startLimitIntervalSec = 3600;
      startLimitBurst = 10;
      # ProtectSystem=strict makes /run read-only; this directory is the one write.
      serviceConfig = base // {
        User = user;
        Group = group;
        ExecStart = "${pkgs.socat}/bin/socat UNIX-LISTEN:${socket},fork,mode=0600,unlink-early ${upstream}";
        ReadWritePaths = [ directory ];
        Restart = "always";
        RestartSec = "2s";
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        IPAddressAllow = "localhost";
        IPAddressDeny = "any";
      };
    };
in
{
  options.photoTriage = {
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../lib/photo-triage/package.nix { };
      description = "The photo-triage package to run.";
    };
    readKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        File containing the Immich read/score API key. The scorer unit loads it
        as the immich-read-key credential; set it from the host's sops secret.
      '';
    };
    albumKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        File containing the Immich album-writer API key. Only the albums command
        loads it, as the immich-album-key credential.
      '';
    };
  };

  config = {
    warnings =
      lib.optionals (cfg.readKeyFile == null) [
        "photo-triage: photoTriage.readKeyFile is not configured; scan and analyze will fail at runtime"
      ]
      ++ lib.optionals (cfg.albumKeyFile == null) [
        "photo-triage: photoTriage.albumKeyFile is not configured; album sync and preflight will fail at runtime"
      ];
    users.groups.${group} = { };
    users.users.${user} = {
      isSystemUser = true;
      inherit group;
      home = dataDir;
      createHome = false;
      description = "Local photo-triage scorer";
    };

    systemd.tmpfiles.rules = [
      "d ${runtimeDir} 0750 ${user} ${group} -"
      "d ${albumRuntimeDir} 0750 ${user} ${group} -"
      "d ${dataDir} 0750 ${user} ${group} -"
    ];

    systemd.services.photo-triage-immich-relay = mkRelay {
      description = "photo-triage Immich Unix-socket relay";
      socket = immichSocket;
      upstream = "TCP:${immichUpstream}";
      after = [ "immich-server.service" ];
    };
    systemd.services.photo-triage-immich-album-relay = mkRelay {
      description = "photo-triage Immich album-writer Unix-socket relay";
      socket = immichAlbumSocket;
      directory = albumRuntimeDir;
      upstream = "TCP:${immichUpstream}";
      after = [ "immich-server.service" ];
    };
    systemd.services.llama-cpp-photo-triage = {
      description = "llama.cpp photo-triage scoring server";
      # Manual: the orchestrator's maintenance window starts this and stops it.
      wantedBy = [ ];
      conflicts = [ "llama-cpp.service" ];
      requires = [
        "nvidia-uvm.service"
        "photo-triage-maintenance.service"
      ];
      after = [
        "nvidia-uvm.service"
        "photo-triage-maintenance.service"
      ];
      restartIfChanged = false;
      onFailure = [
        "photo-triage-restore.service"
        "cloudflare-email@%n.service"
      ];
      startLimitIntervalSec = 3600;
      startLimitBurst = 10;
      serviceConfig = base // {
        ExecStart = scoringExec;
        # ProtectSystem=strict would otherwise make the socket bind fail.
        RuntimeDirectory = "photo-triage";
        RuntimeDirectoryMode = "0750";
        RuntimeDirectoryPreserve = "yes";
        Restart = "on-failure";
        RestartSec = "300s";
        TimeoutStartSec = "1h";
        User = user;
        Group = group;
        SupplementaryGroups = [ "video" ];
        StateDirectory = "llama-cpp-photo-triage";
        StateDirectoryMode = "0700";
        CacheDirectory = "llama-cpp-photo-triage";
        CacheDirectoryMode = "0700";
        WorkingDirectory = "/var/lib/llama-cpp-photo-triage";
        Environment = [ "LLAMA_CACHE=/var/cache/llama-cpp-photo-triage" ];
        # The GPU needs the real device nodes; everything else stays sandboxed.
        PrivateDevices = false;
        PrivateUsers = true;
        PrivateMounts = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
        IPAddressAllow = "localhost";
        IPAddressDeny = "any";
        MemoryDenyWriteExecute = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        AmbientCapabilities = [ "" ];
        SystemCallFilter = base.SystemCallFilter ++ [ "~@privileged" ];
        SystemCallErrorNumber = "EPERM";
        RestrictNamespaces = true;
        ProtectClock = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        RemoveIPC = true;
      };
    };

    systemd.services.photo-triage-maintenance = {
      description = "photo-triage maintenance window";
      # Bound to the run: a run stop/failure ends the window, but a run
      # restart leaves the window (and the scoring server) up.
      bindsTo = [ "photo-triage.service" ];
      restartIfChanged = false;
      onFailure = [
        "photo-triage-restore.service"
        "cloudflare-email@%n.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "photo-triage-maintenance-start" ''
          ${pkgs.coreutils}/bin/mkdir -p ${runtimeDir}
          ${pkgs.coreutils}/bin/touch ${maintenance}
          ${pkgs.systemd}/bin/systemctl stop --no-block llama-cpp.service || true
        '';
        ExecStop = windowStop;
      };
    };

    systemd.services.photo-triage-restore = {
      description = "restore the interactive model after a photo-triage failure";
      onFailure = [ "cloudflare-email@%n.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = windowStop;
      };
    };

    systemd.services.photo-triage = {
      description = "Local photo-triage orchestrator";
      # Manual, and deliberately not wantedBy anything: the operator opens the
      # maintenance window with `systemctl start photo-triage.service`.
      requires = [
        "photo-triage-immich-relay.service"
        "llama-cpp-photo-triage.service"
      ];
      wants = [ "photo-triage-maintenance.service" ];
      after = [
        "photo-triage-immich-relay.service"
        "photo-triage-maintenance.service"
        "llama-cpp-photo-triage.service"
      ];
      restartIfChanged = false;
      onFailure = [
        "photo-triage-restore.service"
        "cloudflare-email@%n.service"
      ];
      startLimitIntervalSec = 86400;
      startLimitBurst = 10;
      serviceConfig = base // {
        User = user;
        Group = group;
        Type = "notify";
        NotifyAccess = "main";
        WatchdogSec = "600s";
        RuntimeMaxSec = "7 days";
        TimeoutStartSec = "1h";
        TimeoutStopSec = "600s";
        ExecStart = "${cfg.package}/bin/photo-triage orchestrate";
        StateDirectory = "photo-triage";
        StateDirectoryMode = "0750";
        WorkingDirectory = dataDir;
        Environment = [
          "PHOTO_TRIAGE_UNIT=1"
          "PHOTO_TRIAGE_DATA_DIR=${dataDir}"
          "PHOTO_TRIAGE_IMMICH_SOCKET=${immichSocket}"
          "PHOTO_TRIAGE_LLM_SOCKET=${llmSocket}"
          "PHOTO_TRIAGE_MODEL=${models.modelAlias}"
          "PHOTO_TRIAGE_MODEL_ID=${models.mainModelHash}"
          "PHOTO_TRIAGE_MMPROJ_SHA256=${models.mmprojHash}"
        ];
        Restart = "on-failure";
        RestartSec = "30s";
        # 2 is a deliberate rejection (validation, no assets); do not loop.
        RestartPreventExitStatus = [ 2 ];
        LoadCredential = lib.optionals (cfg.readKeyFile != null) [
          "immich-read-key:${cfg.readKeyFile}"
        ];
        # Previews live in RAM; the shared sandbox's PrivateTmp is disk-backed here.
        PrivateTmp = "disconnected";
        PrivateNetwork = true;
        PrivateIPC = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        # /run stays visible for the notify socket; bind the relay directory so
        # the scorer sees a restarted relay, and block the egress sockets.
        BindReadOnlyPaths = [ runtimeDir ];
        InaccessiblePaths = [
          "/nix/var/nix/daemon-socket"
          "/run/dbus"
          "/dev/shm"
        ];
        ProtectProc = "invisible";
        ProcSubset = "pid";
      };
    };

    environment.systemPackages = [
      admin
      albumsAdmin
      calibrationAdmin
      calibrationPublishAdmin
    ];

    assertions = [
      {
        assertion = !(lib.hasPrefix "${config.users.users.${config.machine.username}.home}/" dataDir);
        message = "photo-triage: the data root must be outside the human home";
      }
      {
        assertion = !(lib.hasPrefix "/var/lib/agent-vm" dataDir);
        message = "photo-triage: the data root must not be under the agent VM tree";
      }
      {
        assertion = !(config.services ? immich) || config.services.immich.enable;
        message = "photo-triage: Immich must be enabled on this host";
      }
    ];
  };
}
