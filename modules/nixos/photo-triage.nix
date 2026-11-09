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
  immichSocket = "${runtimeDir}/immich.sock";
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
    export PHOTO_TRIAGE_LLM_SOCKET=${llmSocket}
    export PHOTO_TRIAGE_MODEL=${models.modelAlias}
    export PHOTO_TRIAGE_MODEL_ID=${models.mainModelHash}
    export PHOTO_TRIAGE_MMPROJ_SHA256=${models.mmprojHash}
    exec ${cfg.package}/bin/photo-triage "$@"
  '';
  admin = pkgs.writeShellScriptBin "photo-triage-admin" ''
    exec /run/wrappers/bin/sudo -u ${user} -- ${adminRun} "$@"
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
        ReadWritePaths = [ runtimeDir ];
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
  };

  config = {
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
      "d ${dataDir} 0750 ${user} ${group} -"
    ];

    systemd.services.photo-triage-immich-relay = mkRelay {
      description = "photo-triage Immich Unix-socket relay";
      socket = immichSocket;
      upstream = "TCP:${immichUpstream}";
      after = [ "immich-server.service" ];
    };
    systemd.services.llama-cpp-photo-triage = {
      description = "llama.cpp photo-triage scoring server";
      # Manual: T10's orchestrator stops the interactive server and starts this one.
      wantedBy = [ ];
      conflicts = [ "llama-cpp.service" ];
      requires = [ "nvidia-uvm.service" ];
      after = [ "nvidia-uvm.service" ];
      startLimitIntervalSec = 3600;
      startLimitBurst = 10;
      serviceConfig = base // {
        ExecStart = scoringExec;
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

    systemd.services.photo-triage = {
      description = "Local photo-triage scorer";
      # Manual, and deliberately not wantedBy anything: the run is started by the
      # operator (T10 adds the maintenance-window orchestrator).
      requires = [ "photo-triage-immich-relay.service" ];
      after = [ "photo-triage-immich-relay.service" ];
      startLimitIntervalSec = 3600;
      startLimitBurst = 10;
      serviceConfig = base // {
        User = user;
        Group = group;
        ExecStart = "${cfg.package}/bin/photo-triage run";
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
        RestartSec = "5s";
        RestartPreventExitStatus = [
          1
          2
        ];
        # Previews live in RAM; the shared sandbox's PrivateTmp is disk-backed here.
        PrivateTmp = "disconnected";
        PrivateNetwork = true;
        PrivateIPC = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        TemporaryFileSystem = [ "/run" ];
        # Bind the directory, not the socket inodes: a relay restart replaces the
        # socket and the scorer must see the new one.
        BindReadOnlyPaths = [ runtimeDir ];
        InaccessiblePaths = [
          "/nix/var/nix/daemon-socket"
          "/dev/shm"
        ];
        ProtectProc = "invisible";
        ProcSubset = "pid";
      };
    };

    environment.systemPackages = [ admin ];

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
