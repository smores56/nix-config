# Read-only file search over allowlisted home directories, served as MCP to
# LobeChat. The server is loopback-only; path confinement, secret filtering,
# and the employer check live in `memory_mcp.files`, which reuses memory's work
# markers so a work checkout can never be searched from the phone.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.filesearch;
  ports = import ../ports.nix;
  memoryPackage = import ../features/ai/memory/package.nix { inherit pkgs; };
  work = config.user.work;
  workSshMarker = baseNameOf work.sshConfig;
in
{
  options.filesearch = {
    enable = lib.mkEnableOption "the read-only file-search MCP for LobeChat";

    roots = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Absolute directories the server may read. Everything outside them is
        refused, including symlink targets.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.roots != [ ];
        message = "filesearch requires at least one root.";
      }
      {
        assertion = lib.unique cfg.roots == cfg.roots;
        message = "filesearch roots must not repeat.";
      }
      {
        assertion = ports.filesMcp != ports.memoryMcp;
        message = "filesearch's port must differ from the memory wrapper's.";
      }
    ];

    systemd.services.files-mcp = {
      description = "Read-only file search MCP over allowlisted home directories";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      unitConfig = {
        StartLimitIntervalSec = "1h";
        StartLimitBurst = 10;
      };
      onFailure = lib.optional config.alerting.enable "cloudflare-email@%n.service";
      serviceConfig = {
        ExecStart = "${memoryPackage}/bin/memory-file-mcp";
        # The roots live under the human's 0700 home, so the service runs as
        # that user rather than as a DynamicUser.
        User = config.machine.username;
        Environment = [
          "FILE_MCP_HOST=127.0.0.1"
          "FILE_MCP_PORT=${toString ports.filesMcp}"
          "FILE_MCP_ROOTS=${lib.concatStringsSep ":" cfg.roots}"
          # Same refusal inputs as memory; a work checkout is refused even when
          # it sits inside an allowed root.
          "MEMORY_WORK_EMAIL=${work.email}"
          "MEMORY_WORK_OWNER_GLOB=${work.githubOwnerGlob}"
          "MEMORY_WORK_FLOW=${work.flow}"
          "MEMORY_WORK_SSH_MARKER=${workSshMarker}"
        ];
        Restart = "always";
        RestartSec = "5s";
        ProtectSystem = "strict";
        # Read-only: the server never writes, but it must see the roots.
        ProtectHome = "read-only";
        PrivateTmp = true;
        PrivateDevices = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        LockPersonality = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
        ];
        IPAddressAllow = "localhost";
        IPAddressDeny = "any";
      };
    };
  };
}
