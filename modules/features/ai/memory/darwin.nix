# Darwin runner for the memory service description (`./service.nix`): launchd user agents and
# the Docker Desktop CLI. Returns home-manager config for the host module that supplies the
# instance (`modules/hosts/smoreswork/memory.nix`).
#
# Docker Desktop cannot share the host network, so each container publishes on 127.0.0.1 and
# reaches host services through `host.docker.internal`. launchd orders nothing: every agent
# waits for what it needs and exits non-zero when it is not there, and KeepAlive retries.
# Docker Desktop must be running (set it to start at login) or the container agents keep
# waiting for its socket.
{
  lib,
  pkgs,
  config,
  service,
  memoryPackage,
  # Path of the file holding the upstream API key; read at run time, never copied into the store.
  keyFile,
  # Days of dated exports kept under `exportDir`.
  keepExports ? 7,
}:
let
  home = config.home.homeDirectory;
  docker = "/usr/local/bin/docker";
  dockerHost = "unix://${home}/.docker/run/docker.sock";

  stateDir = "${home}/.local/share/memory";
  falkordbDir = "${stateDir}/falkordb";
  # Docker Desktop shares /Users but not /nix, so Graphiti's config is copied here at start.
  graphitiConfigFile = "${stateDir}/graphiti-config.yaml";
  # Inside the home directory, so FileVault covers it; no off-machine copy exists.
  exportDir = "${home}/.local/share/memory-export";
  claudeCwd = "${stateDir}/claude-cwd";
  # Local-only credential: the listener is loopback, but every request still needs the bearer.
  tokenFile = "${stateDir}/mcp-token";
  logDir = "${home}/Library/Logs";

  # Hour and minute of the nightly export; launchd runs a missed one after wake.
  exportAt = {
    Hour = 3;
    Minute = 17;
  };

  basePath = "${pkgs.coreutils}/bin:/usr/bin:/bin:/usr/sbin:/sbin";
  # `docker run` pulls through docker-credential-desktop (credsStore in ~/.docker/config.json),
  # which Docker Desktop installs next to the CLI.
  dockerPath = "/usr/local/bin:${basePath}";
  script =
    name: text:
    pkgs.writeShellScript name ''
      export PATH=${basePath}
      ${text}
    '';
  dockerScript =
    name: text:
    pkgs.writeShellScript name ''
      export PATH=${dockerPath}
      ${text}
    '';

  # The nightly job runs unattended and launchd logs go unread: a failed export (including a
  # failed graph snapshot, which exits non-zero) must reach the user.
  exportRun = script "memory-export-run" ''
    "$@"
    rc=$?
    [ "$rc" -eq 0 ] && exit 0
    # argv, not interpolation, like the harvest notification.
    /usr/bin/osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title "Memory export"' \
      -e 'end run' "Export failed (exit $rc); see ~/Library/Logs/memory-export.log" || true
    exit "$rc"
  '';

  graphitiReady = script "memory-graphiti-ready" service.graphitiReady;
  wrapperReady = script "memory-mcp-ready" service.wrapperReady;

  waitForDocker = ''
    export DOCKER_HOST=${lib.escapeShellArg dockerHost}
    for _ in $(seq 300); do
      ${docker} info >/dev/null 2>&1 && break
      sleep 2
    done
    ${docker} info >/dev/null 2>&1 || { echo "Docker Desktop is not running" >&2; exit 1; }
  '';

  dockerRun =
    {
      name,
      container,
      volumes,
    }:
    lib.escapeShellArgs (
      [
        docker
        "run"
        "--rm"
        "--name"
        name
        "--publish"
        "127.0.0.1:${toString container.hostPort}:${toString container.containerPort}"
      ]
      ++ lib.concatMap (v: [
        "--volume"
        v
      ]) volumes
      ++ lib.concatMap (n: [
        "--env"
        "${n}=${container.environment.${n}}"
      ]) (builtins.attrNames container.environment)
      ++ container.hardening
      ++ container.healthArgs
      ++ [ container.image ]
    );

  containerAgent =
    {
      name,
      container,
      volumes,
      before ? "",
    }:
    {
      enable = true;
      config = {
        ProgramArguments = [
          "${dockerScript name ''
            ${waitForDocker}
            ${before}
            # A crashed run can leave its name behind.
            ${docker} rm --force ${name} >/dev/null 2>&1 || true
            exec ${dockerRun { inherit name container volumes; }}
          ''}"
        ];
        RunAtLoad = true;
        KeepAlive = true;
        ThrottleInterval = 10;
        # The container's own output stays in `docker logs`; a foreground run would otherwise
        # grow a file without bound.
        StandardOutPath = "/dev/null";
        StandardErrorPath = "${logDir}/${name}.log";
      };
    };

  serviceAgent =
    {
      name,
      start,
      environment,
    }:
    {
      enable = true;
      config = {
        ProgramArguments = [ "${script name start}" ];
        EnvironmentVariables = {
          HOME = home;
        }
        // service.toAttrs environment;
        RunAtLoad = true;
        KeepAlive = true;
        ThrottleInterval = 10;
        StandardOutPath = "${logDir}/${name}.log";
        StandardErrorPath = "${logDir}/${name}.log";
      };
    };

  clientEnvironment = service.clientEnvironment ++ [
    [
      "MEMORY_MCP_URL"
      "http://127.0.0.1:${toString service.mcpPort}/mcp"
    ]
    [
      "MEMORY_MCP_TOKEN_FILE"
      tokenFile
    ]
  ];

  # The CLI and the shim read the token file and the work policy from the environment.
  memoryCli = pkgs.writeShellScriptBin "memory" ''
    ${lib.concatMapStrings (
      p: "export ${builtins.elemAt p 0}=${lib.escapeShellArg (builtins.elemAt p 1)}\n"
    ) clientEnvironment}
    exec ${memoryPackage}/bin/memory "$@"
  '';
in
{
  home.packages = [ memoryCli ];

  ai.claude.mcpServers.memory = {
    type = "stdio";
    command = "${memoryPackage}/bin/memory-mcp-shim";
    args = [ ];
    env = service.toAttrs clientEnvironment;
  };

  launchd.agents = {
    memory-falkordb = containerAgent {
      name = "memory-falkordb";
      container = service.containers.falkordb;
      volumes = service.containers.falkordb.mountsFor falkordbDir;
      before = "mkdir -p ${lib.escapeShellArg falkordbDir}";
    };

    memory-graphiti-mcp = containerAgent {
      name = "memory-graphiti-mcp";
      container = service.containers.graphiti;
      volumes = service.containers.graphiti.mountsFor graphitiConfigFile;
      before = ''
        ${graphitiReady} || exit 1
        mkdir -p ${lib.escapeShellArg stateDir}
        install -m 0644 ${service.graphitiConfig} ${lib.escapeShellArg graphitiConfigFile}
      '';
    };

    memory-llm-proxy = serviceAgent {
      name = "memory-llm-proxy";
      environment = service.proxyEnvironment keyFile;
      # sops-nix decrypts at login, possibly after this agent starts.
      start = ''
        for _ in $(seq 60); do
          [ -s ${lib.escapeShellArg keyFile} ] && break
          sleep 2
        done
        # An empty directory: `claude -p` would otherwise read a project's CLAUDE.md from the cwd.
        mkdir -p ${lib.escapeShellArg claudeCwd}
        cd ${lib.escapeShellArg claudeCwd}
        exec ${memoryPackage}/bin/memory-llm-proxy
      '';
    };

    memory-mcp = serviceAgent {
      name = "memory-mcp";
      environment = service.wrapperEnvironment {
        inherit stateDir;
        extra = [
          [
            "MEMORY_MCP_TOKEN_FILE"
            tokenFile
          ]
        ];
      };
      start = ''
        mkdir -p ${lib.escapeShellArg stateDir}
        cd ${lib.escapeShellArg stateDir}
        if [ ! -s ${lib.escapeShellArg tokenFile} ]; then
          (umask 077; head -c 32 /dev/urandom | base64 >${lib.escapeShellArg tokenFile})
        fi
        ${wrapperReady} || exit 1
        exec ${memoryPackage}/bin/memory-mcp
      '';
    };

    memory-export = {
      enable = true;
      config = {
        ProgramArguments = [
          "${exportRun}"
        ]
        ++ service.exportArguments {
          inherit exportDir stateDir;
          graphDir = falkordbDir;
          extra = [
            "--keep"
            (toString keepExports)
          ];
        };
        EnvironmentVariables = {
          HOME = home;
          PATH = basePath;
        };
        StartCalendarInterval = [ exportAt ];
        ProcessType = "Background";
        LowPriorityIO = true;
        Nice = 19;
        StandardOutPath = "${logDir}/memory-export.log";
        StandardErrorPath = "${logDir}/memory-export.log";
      };
    };
  };
}
