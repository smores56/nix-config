# Personal-only: the work machine never reaches this store. The MCP origin is
# loopback; off-host access goes through the Cloudflare Access route.
{
  config,
  lib,
  pkgs,
  aiProviders,
  ...
}:
let
  hardening = import ../lib/hardening.nix;
  ports = import ../ports.nix;
  inherit (aiProviders) neuralwatt;
  memoryPackage = import ../features/ai/memory/package.nix { inherit pkgs; };

  # tmpfiles owns the falkordb subdirectory of the StateDirectory.
  stateDirectory = "memory";
  dataDir = "/var/lib/${stateDirectory}";
  # Pinned so RequiresMountsFor and user@ never see a null uid; matches ids on smortress.
  memoryUid = 982;
  memoryGid = 977;
  # `smores` is the only normal user; revisit if another is added.
  memorySubidStart = 200000;
  # Root-owned, inside the durable tree. A real directory: restic does not follow symlinks.
  exportDir = "/var/lib/data/memory-export";

  # Host networking lets the containers reach the gateway and FalkorDB on 127.0.0.1.
  service = import ../features/ai/memory/service.nix {
    inherit
      lib
      pkgs
      memoryPackage
      ports
      ;
    # Shared with the shim so both agree on what a work repo is.
    work = config.user.work;
    workPolicy = if config.user.aiProfile == "work" then "allow" else "refuse";
    containerHost = "127.0.0.1";
    graphitiListen = "127.0.0.1";
    # Loopback gateway to Neuralwatt, never tunneled. It injects the key and adds
    # `reasoning_effort: "none"` because reasoning extraction returns empty content.
    llm = {
      model = neuralwatt.models.deepseekFlash.id;
      upstream = "https://api.neuralwatt.com";
      reasoningEffort = "none";
      chatBackend = "upstream";
      # Two of the tier's three slots; six attempts absorb 429/503 bursts.
      concurrency = 2;
      retries = 6;
    };
    embedder = {
      model = "qwen3-embedding-8b";
      dimensions = 4096;
    };
  };
  inherit (service) dbPort graphitiPort;
  llmProxyPort = service.proxyPort;
  container = service.containers;

  # Bounds the start of a unit that pulls an image or probes a slow dependency.
  restartPolicy = {
    TimeoutStartSec = lib.mkForce "30m";
    Restart = lib.mkForce "always";
    RestartSec = "10s";
  };
  userManager = [
    "user-runtime-dir@${toString memoryUid}.service"
    "user@${toString memoryUid}.service"
  ];
in
{
  config = {
    inherit (service) assertions;

    # Both containers run rootless as `memory`; FalkorDB publishes to loopback only.
    virtualisation.oci-containers.backend = "podman";

    users.groups.memory = {
      gid = memoryGid;
    };
    users.users.memory = {
      isSystemUser = true;
      uid = memoryUid;
      group = "memory";
      home = dataDir;
      createHome = true;
      # The human user must keep group access to the wrapper token and registry.
      homeMode = "0750";
      linger = true;
      subUidRanges = [
        {
          startUid = memorySubidStart;
          count = 65536;
        }
      ];
      subGidRanges = [
        {
          startGid = memorySubidStart;
          count = 65536;
        }
      ];
    };
    # The MCP token is root:memory 0440 (secrets-common.nix); the operator reads it via group.
    users.users.${config.machine.username}.extraGroups = [ "memory" ];

    systemd.tmpfiles.rules = [
      "d ${dataDir}/falkordb 0700 memory memory -"
      "d ${exportDir} 0700 root root -"
    ];

    # sudo resolves commands on root's secure_path, so `sudo memory restore` needs
    # the system profile.
    environment.systemPackages = [ memoryPackage ];

    virtualisation.oci-containers.containers = {
      memory-falkordb = {
        serviceName = "memory-falkordb";
        image = container.falkordb.image;
        podman.user = "memory";
        ports = [ "127.0.0.1:${toString dbPort}:${toString container.falkordb.containerPort}" ];
        volumes = container.falkordb.mountsFor "${dataDir}/falkordb";
        extraOptions =
          container.falkordb.hardening
          ++ container.falkordb.healthArgs
          # A hung database must exit so the unit's Restart can act on it.
          ++ [ "--health-on-failure=kill" ];
        inherit (container.falkordb) environment;
      };

      memory-graphiti-mcp = {
        serviceName = "memory-graphiti-mcp";
        image = container.graphiti.image;
        podman.user = "memory";
        extraOptions = [
          "--network=host"
        ]
        ++ container.graphiti.hardening
        ++ container.graphiti.healthArgs;
        volumes = container.graphiti.mountsFor service.graphitiConfig;
        inherit (container.graphiti) environment;
      };
    };

    # No dependsOn: a FalkorDB restart would stop the MCP and drop its episode queue.
    # Ten starts per hour then `failed` + email; TimeoutStartSec bounds a hung pull.
    systemd.services.memory-falkordb = {
      # linger-users only enables lingering; require the user manager for cgroups and
      # XDG_RUNTIME_DIR.
      requires = userManager;
      after = userManager;
      environment.XDG_RUNTIME_DIR = "/run/user/${toString memoryUid}";
      unitConfig = {
        StartLimitIntervalSec = "1h";
        StartLimitBurst = 10;
      };
      serviceConfig = restartPolicy;
      onFailure = [ "cloudflare-email@%n.service" ];
    };

    systemd.services.memory-graphiti-mcp = {
      requires = [
        "user-runtime-dir@${toString memoryUid}.service"
        "user@${toString memoryUid}.service"
      ];
      environment.XDG_RUNTIME_DIR = "/run/user/${toString memoryUid}";
      wants = [
        "memory-falkordb.service"
        "memory-llm-proxy.service"
      ];
      after = userManager ++ [
        "memory-falkordb.service"
        "memory-llm-proxy.service"
      ];
      unitConfig = {
        StartLimitIntervalSec = "1h";
        StartLimitBurst = 10;
      };
      serviceConfig = restartPolicy;
      onFailure = [ "cloudflare-email@%n.service" ];
      preStart = service.graphitiReady;
    };

    # Sole route to Neuralwatt: holds the key and adds `reasoning_effort: "none"`
    # (graphiti-core cannot per request); forwards the rest, replacing the dummy
    # `Bearer none`. Fails to start without the key.
    systemd.services.memory-llm-proxy = {
      description = "Neuralwatt gateway for Graphiti extraction (key injection, thinking off)";
      wantedBy = [ "multi-user.target" ];
      unitConfig = {
        StartLimitIntervalSec = "1h";
        StartLimitBurst = 10;
      };
      onFailure = [ "cloudflare-email@%n.service" ];
      serviceConfig = hardening // {
        DynamicUser = true;
        ExecStart = "${memoryPackage}/bin/memory-llm-proxy";
        # %d is systemd's credential directory: the key never enters the environment or store.
        Environment = service.toStrings (service.proxyEnvironment "%d/neuralwatt-api-key");
        # A missing key fails the unit instead of serving unauthenticated calls.
        LoadCredential = "neuralwatt-api-key:/run/secrets/neuralwatt-api-key";
        Restart = "always";
        RestartSec = "5s";
        # Streaming relay with tiny requests.
        MemoryMax = "256M";
        PrivateDevices = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        # Sole off-host route of the memory stack, so no IP filters.
      };
    };

    # The only service the tunnel reaches. A raw TCP tunnel presents every client as
    # loopback, so each request needs the bearer token (/run/secrets/memory-mcp-token,
    # the wrapper's default path); /health is exempt. A missing secret fails closed (503).
    # Raw Graphiti is never tunneled.
    systemd.services.memory-mcp = {
      description = "memory MCP wrapper (project groups, typed registry, reconciler)";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "memory-graphiti-mcp.service"
        "memory-llm-proxy.service"
      ];
      after = [
        "memory-graphiti-mcp.service"
        "memory-llm-proxy.service"
      ];
      unitConfig = {
        StartLimitIntervalSec = "1h";
        StartLimitBurst = 10;
      };
      onFailure = [ "cloudflare-email@%n.service" ];
      serviceConfig = hardening // {
        User = "memory";
        Group = "memory";
        ExecStart = "${memoryPackage}/bin/memory-mcp";
        WorkingDirectory = dataDir;
        StateDirectory = stateDirectory;
        StateDirectoryMode = "0750";
        Environment = service.toStrings (
          service.wrapperEnvironment {
            stateDir = dataDir;
            extra = [
              # Open WebUI's MCP client cannot send X-Memory-* headers; pin it to the shared
              # group. Header-sending clients keep the strict contract.
              [
                "MEMORY_MCP_DEFAULT_GROUP"
                "global"
              ]
              [
                "MEMORY_MCP_DEFAULT_CWD"
                "/chat"
              ]
              [
                "MEMORY_MCP_DEFAULT_ACTOR"
                "open-webui"
              ]
              [
                "MEMORY_MCP_DEFAULT_MACHINE"
                config.networking.hostName
              ]
            ];
          }
        );
        # Bounds how long the pre-start probe can hold activation.
        TimeoutStartSec = "2min";
        Restart = "always";
        RestartSec = "5s";
        MemoryMax = "512M";
        PrivateDevices = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        # Loopback only; rootless port forwarding presents FalkorDB there.
        IPAddressAllow = "localhost";
        IPAddressDeny = "any";
      };
      preStart = service.wrapperReady;
    };

    # Overwrites registry.sqlite, episodes.jsonl and graph.rdb in exportDir; restic keeps the
    # history. The graph is a derived index, so its BGSAVE is best-effort but a missing graph
    # exits non-zero to trigger the alert. Root reads the memory-owned graph dir. Refuses to
    # run during a restore (.restore-in-progress).
    systemd.services.memory-export = {
      description = "Export the memory registry and snapshot the graph";
      # No dependency on the wrapper: exporting while services are down is the point.
      # `after` only orders runs in one transaction.
      after = [ "memory-mcp.service" ];
      # A restic run that starts mid-export must wait, so a snapshot never captures a half-written set.
      before = [
        "restic-backups-r2.service"
        "restic-backups-local.service"
      ];
      unitConfig = {
        StartLimitIntervalSec = "1h";
        StartLimitBurst = 3;
      };
      onFailure = [ "cloudflare-email@%n.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.escapeShellArgs (
          service.exportArguments {
            inherit exportDir;
            stateDir = dataDir;
            graphDir = "${dataDir}/falkordb";
          }
        );
        # A copy must never compete with the store it copies.
        Nice = 19;
        CPUWeight = 20;
        IOSchedulingClass = "idle";
        TimeoutStartSec = "30min";
        TimeoutStopSec = "30min";
        # Keeps /var writable (export and graph live there).
        ProtectSystem = "full";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
        ];
        # Rootless port forwarding presents FalkorDB on localhost.
        IPAddressAllow = "localhost";
        IPAddressDeny = "any";
      };
    };

    systemd.timers.memory-export = {
      description = "Nightly memory registry export";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
        # Spread away from midnight and the backup timers.
        RandomizedDelaySec = "1h";
        Unit = "memory-export.service";
      };
    };
  };
}
