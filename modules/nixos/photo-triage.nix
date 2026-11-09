# Local photo triage: a dedicated system user, a fixed data root, two Unix-socket
# relays, and a scorer with no IP stack. The scoring server and the run itself are
# added by later tasks; this module owns the boundary they must live inside.
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

  user = "photo-triage";
  group = user;
  dataDir = "/var/lib/photo-triage";
  runtimeDir = "/run/photo-triage";
  immichSocket = "${runtimeDir}/immich.sock";
  llmSocket = "${runtimeDir}/llm.sock";
  immichUpstream = "127.0.0.1:${toString ports.immich}";
  llmUpstream = "127.0.0.1:${toString cfg.llmPort}";

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
    exec ${cfg.package}/bin/photo-triage "$@"
  '';
  admin = pkgs.writeShellScriptBin "photo-triage-admin" ''
    exec /run/wrappers/bin/sudo -u ${user} -- ${adminRun} "$@"
  '';

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
      # ProtectSystem=strict makes /run read-only; this directory is the one write.
      serviceConfig = base // {
        User = user;
        Group = group;
        ExecStart = "${pkgs.socat}/bin/socat UNIX-LISTEN:${socket},fork,mode=0600,unlink-early ${upstream}";
        ReadWritePaths = [ runtimeDir ];
        Restart = "always";
        RestartSec = "2s";
        StartLimitIntervalSec = "1h";
        StartLimitBurst = 10;
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
    llmPort = lib.mkOption {
      type = lib.types.port;
      default = ports.photoTriageLlm;
      description = "Loopback port of the dedicated scoring llama.cpp.";
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
    systemd.services.photo-triage-llm-relay = mkRelay {
      description = "photo-triage scoring-model Unix-socket relay";
      socket = llmSocket;
      upstream = "TCP:${llmUpstream}";
    };

    systemd.services.photo-triage = {
      description = "Local photo-triage scorer";
      # Manual, and deliberately not wantedBy anything: the run is started by the
      # operator (T10 adds the maintenance-window orchestrator).
      requires = [
        "photo-triage-immich-relay.service"
        "photo-triage-llm-relay.service"
      ];
      after = [
        "photo-triage-immich-relay.service"
        "photo-triage-llm-relay.service"
      ];
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
        ];
        Restart = "on-failure";
        RestartSec = "5s";
        StartLimitIntervalSec = "1h";
        StartLimitBurst = 10;
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
        assertion = cfg.llmPort != ports.immich && cfg.llmPort != ports.llm;
        message = "photo-triage: llmPort must not collide with Immich or the interactive LLM";
      }
      {
        assertion = !(config.services ? immich) || config.services.immich.enable;
        message = "photo-triage: Immich must be enabled on this host";
      }
    ];
  };
}
