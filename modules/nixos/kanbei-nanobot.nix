# nanobot in the kanbei guest (smores56/sdlc#642, T2): the owner's WebUI and the agent
# loop the later tasks point at read-only ledger tools (T4). It is a second,
# capability-free instance of the wheel the cluster agent runs: no broker, no operator
# skills, no MCP server, and every listener on loopback. `kanbei-ui` stays the TLS
# terminator until T5 repoints it here.
#
# Imported by the guest config in `modules/nixos/kanbei-vm.nix`, so it only evaluates
# while `kanbeiVm.enable` is set.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  ports = import ../lib/kanbei-nanobot.nix;
  inference = import ../lib/kanbei-inference.nix { inherit lib; };

  # The payload identity uid 1000: the same uid the inference lanes and `kanbei-ui` use,
  # and the uid the share translations map to the host's `vault` user.
  user = "kanbei";
  group = "kanbei";

  # Everything nanobot writes — config, sessions SQLite, workspace — stays on the LUKS
  # volume: the guest journal and /tmp die with the guest.
  stateDir = "/var/lib/kanbei/nanobot";
  instanceDir = "${stateDir}/.nanobot";

  nanobotConfig = {
    gateway = {
      host = "127.0.0.1";
      port = ports.gatewayPort;
      # The heartbeat is a cron job that wakes the agent every 30 minutes. In the guest
      # that is a model turn against the only GPU, and the owner never asked for one.
      heartbeat.enabled = false;
    };
    channels.websocket = {
      enabled = true;
      host = "127.0.0.1";
      port = ports.webPort;
      # Access fronts the terminator and the guest has no NIC, so a second password would
      # be a token the owner must read out of the LUKS volume, not a second barrier.
      websocket_requires_token = false;
    };
    # The guest's only model endpoint. llama.cpp speaks the OpenAI schema at /v1 and
    # `--alias kanbei-chat` is the id it answers to, so no discovery call is needed.
    providers.custom = {
      apiKey = "none";
      apiBase = "http://127.0.0.1:${toString inference.ports.chat}/v1";
    };
    modelPresets.kanbei = {
      provider = "custom";
      model = "kanbei-chat";
      # llama-server hands every slot the unified pool's per-slot ceiling; a request that
      # assumes more would be rejected there instead of trimmed here.
      contextWindowTokens = inference.lanes.perSlotCap;
      maxTokens = 8192;
    };
    agents.defaults = {
      modelPreset = "kanbei";
      # Every builtin skill reaches a shell, the network, a cluster or the package index.
      # T4 installs exactly the five ledger skills; until then the inventory is empty.
      disabled_skills = [
        "clawhub"
        "cron"
        "github"
        "image-generation"
        "memory"
        "my"
        "nanobot-document"
        "skill-creator"
        "summarize"
        "tmux"
        "weather"
      ];
      dream.enabled = false;
    };
    transcription.enabled = false;
    tools = {
      # No code execution, network fetch, cli apps or image generation in the guest. T4
      # brings the exec tool back only as far as the five ledger scripts need it.
      exec.enable = false;
      web.enable = false;
      cli_apps.enable = false;
      image_generation.enabled = false;
    };
  };

  configFile = pkgs.writeText "kanbei-nanobot-config.json" (builtins.toJSON nanobotConfig);

  runner = pkgs.writeShellApplication {
    name = "kanbei-nanobot";
    runtimeInputs = [
      pkgs.nanobot
      pkgs.coreutils
      pkgs.curl
    ];
    text = ''
      set -eu
      export HOME=${stateDir}
      export XDG_STATE_HOME="$HOME/.local/state"
      export XDG_CACHE_HOME="$HOME/.cache"
      export XDG_DATA_HOME="$HOME/.local/share"
      export PYTHONUNBUFFERED=1
      install -d -m 0700 "$HOME" ${instanceDir} ${instanceDir}/workspace
      # Nix owns the config. The WebUI's Settings page appears to save, but the next start
      # restores what the module declares, so a provider or skill added there is lost.
      # Write beside it and rename: `install` opens a new destination with O_EXCL, so the
      # gateway and the probe racing here is a lost `File exists`, not a bad config.
      config_tmp=$(mktemp ${instanceDir}/config.json.XXXXXX)
      install -m 0600 ${configFile} "$config_tmp"
      mv -f "$config_tmp" ${instanceDir}/config.json
      case "''${1:-gateway}" in
        gateway)
          exec nanobot gateway --foreground --port ${toString ports.gatewayPort}
          ;;
        # One agent turn for the boot probe: llama-server is loading the 27B, so wait for
        # the health endpoint instead of failing the first request.
        probe)
          shift
          for _ in $(seq 1 120); do
            curl -fsS "http://127.0.0.1:${toString inference.ports.chat}/health" >/dev/null 2>&1 && break
            sleep 5
          done
          # A fresh session per boot: history from an earlier probe would let the model
          # answer from context instead of calling a tool. `--logs` is what prints the
          # progress hook's `Tool call: <name>(<args>)` lines.
          exec nanobot agent --classic --logs --no-markdown \
            --session "probe-$(cat /proc/sys/kernel/random/boot_id)" "$@"
          ;;
        *)
          echo "usage: kanbei-nanobot [gateway|probe -m MESSAGE]" >&2
          exit 2
          ;;
      esac
    '';
  };

  sandbox = {
    PrivateDevices = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    NoNewPrivileges = true;
    CapabilityBoundingSet = "";
    AmbientCapabilities = "";
    LockPersonality = true;
    RestrictNamespaces = true;
    RestrictRealtime = true;
    SystemCallArchitectures = "native";
    # Python maps its code pages executable, so MemoryDenyWriteExecute stays off.
    RestrictAddressFamilies = [
      "AF_UNIX"
      "AF_INET"
      "AF_INET6"
      "AF_NETLINK"
    ];
    UMask = "0077";
  };
in
{
  # The LUKS volume root is root-owned and the `kanbei` uid cannot create its own home
  # there, so root creates the 0700 directory once the mount is up.
  systemd.services.kanbei-nanobot-state = {
    description = "Create nanobot's home on the kanbei LUKS volume";
    wantedBy = [ "multi-user.target" ];
    unitConfig.RequiresMountsFor = [ "/var/lib/kanbei" ];
    before = [ "kanbei-nanobot.service" ];
    restartIfChanged = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      UMask = "0077";
    };
    script = ''
      set -euo pipefail
      install -d -m 0700 -o ${user} -g ${group} ${stateDir}
    '';
  };

  systemd.services.kanbei-nanobot = {
    description = "nanobot gateway and WebUI inside the kanbei guest (loopback only)";
    wantedBy = [ "multi-user.target" ];
    requires = [ "kanbei-nanobot-state.service" ];
    after = [ "kanbei-nanobot-state.service" ];
    unitConfig.RequiresMountsFor = [ "/var/lib/kanbei" ];
    restartIfChanged = false;
    serviceConfig = sandbox // {
      Type = "simple";
      User = user;
      Group = group;
      Restart = "always";
      RestartSec = "5s";
      ExecStart = "${runner}/bin/kanbei-nanobot";
      # The only writable path: sessions, workspace and the rendered config.
      ReadWritePaths = [ stateDir ];
      # The guest journal dies with the guest, and a failed start is otherwise only
      # visible to someone inside it. The serial console is the host-kept trace.
      StandardOutput = "journal+console";
      StandardError = "journal+console";
    };
  };

  # T3's spike. Nothing in the guest can be driven from the host until T5 repoints the
  # terminator at the WebUI, so this is the only way to see whether the IQ4_XS checkpoint
  # actually emits tool calls through the Jinja template: one agent turn per boot, with a
  # prompt that cannot be answered without a tool, printed to the serial console. Remove
  # it once the UI lane is live.
  systemd.services.kanbei-nanobot-probe = {
    description = "Prove the nanobot tool-call lane once per boot";
    wantedBy = [ "multi-user.target" ];
    requires = [
      "kanbei-nanobot.service"
      "kanbei-chat.service"
    ];
    after = [
      "kanbei-nanobot.service"
      "kanbei-chat.service"
    ];
    unitConfig = {
      RequiresMountsFor = [ "/var/lib/kanbei" ];
      # A boot that never finishes loading the 27B must not hold the probe for an hour.
      TimeoutStartSec = "15min";
    };
    restartIfChanged = false;
    serviceConfig = sandbox // {
      Type = "oneshot";
      User = user;
      Group = group;
      ExecStart = ''${runner}/bin/kanbei-nanobot probe --message "List the files in your workspace with the tool available to you, then reply with just the file names."'';
      ReadWritePaths = [ stateDir ];
      StandardOutput = "journal+console";
      StandardError = "journal+console";
    };
  };

  assertions = [
    {
      assertion =
        ports.webPort != ports.gatewayPort
        && ports.webPort != ports.kernelChatPort
        && ports.webPort != ports.kernelStatusPort
        && ports.gatewayPort != ports.kernelChatPort
        && ports.gatewayPort != ports.kernelStatusPort
        && ports.kernelChatPort != ports.kernelStatusPort;
      message = "kanbei-nanobot: nanobot, the gateway and the kernel's two lanes must bind distinct loopback ports (the guest cannot recover from EADDRINUSE)";
    }
    {
      assertion =
        nanobotConfig.gateway.host == "127.0.0.1"
        && nanobotConfig.channels.websocket.host == "127.0.0.1"
        && nanobotConfig.channels.websocket.port == ports.webPort;
      message = "kanbei-nanobot: the guest has no NIC and Access fronts the terminator, so nanobot must bind loopback on the port T5 proxies";
    }
    {
      assertion =
        !nanobotConfig.tools.exec.enable
        && !nanobotConfig.tools.web.enable
        && !nanobotConfig.gateway.heartbeat.enabled;
      message = "kanbei-nanobot: no code execution, network fetch or background heartbeat in the guest; a task that needs one must change this config first";
    }
    {
      assertion =
        nanobotConfig.providers.custom.apiBase == "http://127.0.0.1:${toString inference.ports.chat}/v1"
        && nanobotConfig.modelPresets.kanbei.model == "kanbei-chat"
        && nanobotConfig.agents.defaults.modelPreset == "kanbei";
      message = "kanbei-nanobot: the only provider must be the guest's local chat lane (loopback ${toString inference.ports.chat}, alias kanbei-chat); anything else would leave the VM";
    }
    {
      assertion = nanobotConfig.modelPresets.kanbei.contextWindowTokens <= inference.lanes.perSlotCap;
      message = "kanbei-nanobot: the preset must assume no more context than llama-server's per-slot ceiling (${toString inference.lanes.perSlotCap})";
    }
    {
      assertion = config.users.users.${user}.uid == 1000;
      message = "kanbei-nanobot: nanobot runs as the payload identity uid 1000, the uid the shares translate to the host vault user";
    }
    {
      assertion =
        config.systemd.services.kanbei-nanobot.serviceConfig.User == user
        && lib.all (
          path: lib.hasPrefix "/var/lib/kanbei/" path
        ) config.systemd.services.kanbei-nanobot.serviceConfig.ReadWritePaths;
      message = "kanbei-nanobot: the gateway runs as the payload uid and can write only inside the LUKS volume";
    }
  ];
}
