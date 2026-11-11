# The kanbei guest's inference lanes (smores56/sdlc#585, part of #509).
#
# Imported by the guest config in `modules/nixos/kanbei-vm.nix`; it only evaluates while
# `kanbeiVm.enable` is set, because the guest module itself does not exist otherwise.
#
# One llama-server on the 3090 serves the chat lane from a unified q8_0 KV pool sized by
# `modules/lib/kanbei-inference.nix`; two CPU llama-servers serve embeddings and reranking.
# Models are data on the LUKS volume (`/var/lib/kanbei/models`), never in the store: the
# manifest and the fetch/verify tool are `modules/lib/kanbei-models.json` and
# `modules/lib/kanbei-fetch-models.py`.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  hardening = import ../lib/hardening.nix;
  inference = import ../lib/kanbei-inference.nix { inherit lib; };
  models = import ../lib/llama-cpp-models.nix { inherit pkgs; };

  inherit (inference)
    budget
    cacheDir
    chatArgs
    cpu
    embeddingsArgs
    lanes
    modelsDir
    ports
    rerankArgs
    ;

  # T10's dataTranslation maps guest uid/gid 1000 to the host `vault` user on the shared trees,
  # and the doc names that uid as the payload identity. Nothing here writes a share, but the
  # service identity must stay 1000 so a later payload tool keeps the same mapping.
  user = "kanbei";
  group = "kanbei";
  uid = 1000;
  gid = 1000;

  manifestPath = ../lib/kanbei-models.json;
  llamaServer = "${models.llama-cpp}/bin/llama-server";

  # Every argument is a space-free token (paths and numbers), so a plain join is the systemd
  # argv; `lib.escapeShellArgs` would emit single quotes systemd does not interpret.
  execStart = args: "${llamaServer} ${lib.concatStringsSep " " args}";

  # CUDA needs the passthrough device nodes, writable+executable mappings and the host network
  # namespace (loopback is the listener); those three keys stay at their defaults on purpose.
  commonHardening = hardening // {
    ProtectClock = true;
    ProtectHostname = true;
    ProtectKernelLogs = true;
    ProtectKernelModules = true;
    ProtectKernelTunables = true;
    ProtectControlGroups = true;
    RestrictAddressFamilies = [
      "AF_INET"
      "AF_INET6"
      "AF_UNIX"
    ];
    RestrictNamespaces = true;
    LockPersonality = true;
    SystemCallArchitectures = "native";
    # The driver's udev rules can create the device nodes root:video/render rather than 0666;
    # CUDA also probes the nodes in the CPU lanes even with -ngl 0.
    SupplementaryGroups = [
      "video"
      "render"
    ];
    UMask = "0027";
    PrivateDevices = false;
    MemoryDenyWriteExecute = false;
    PrivateNetwork = false;
  };

  gpuReady = pkgs.writeShellScript "kanbei-inference-gpu-ready" ''
    set -eu
    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.kmod
      ]
    }
    smi=${lib.getExe' config.hardware.nvidia.package "nvidia-smi"}
    # Best effort: systemd-modules-load normally wins this race.
    modprobe nvidia_uvm 2>/dev/null || true
    for _ in $(seq 1 120); do
      if [ -c /dev/nvidiactl ] && [ -c /dev/nvidia0 ] && [ -c /dev/nvidia-uvm ]; then
        if total=$("$smi" --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -n1 | tr -d ' '); then
          if [ -n "$total" ] && [ "$total" -ge 24000 ]; then
            echo "kanbei: GPU ready: $("$smi" --query-gpu=name,memory.total --format=csv,noheader)"
            exit 0
          fi
          echo "kanbei: GPU reports ''${total:-0} MiB, expected at least 24000 (RTX 3090)" >&2
          exit 1
        fi
      fi
      sleep 2
    done
    echo "kanbei: the passthrough RTX 3090 did not appear within 240s" >&2
    exit 1
  '';

  inferenceEval = pkgs.writeShellApplication {
    name = "kanbei-inference-eval";
    runtimeInputs = [ pkgs.python3 ];
    text = ''
      exec python3 ${../../tests/inference/run_all.py} "$@"
    '';
  };
in
{
  # The chat model is a GPU model; the CUDA runtime is what needs the driver. No display.
  hardware.nvidia = {
    open = true;
    nvidiaPersistenced = true;
  };
  hardware.graphics.enable = true;
  services.xserver.videoDrivers = [ "nvidia" ];
  # systemd-modules-load loads the dependency chain before kanbei-inference-gpu runs.
  boot.kernelModules = [ "nvidia_uvm" ];

  users.groups.${group} = {
    inherit gid;
  };
  users.users.${user} = {
    isSystemUser = true;
    inherit uid group;
    home = "/var/lib/kanbei";
    description = "kanbei inference lanes";
  };

  environment.systemPackages = [
    models.llama-cpp
    inferenceEval
  ];

  systemd.tmpfiles.rules = [
    "d ${modelsDir} 0750 root ${group} -"
    "d ${cacheDir} 0750 ${user} ${group} -"
    "d ${cacheDir}/cuda 0750 ${user} ${group} -"
  ];

  # The manifest is the path contract: the operator's fetch tool writes the same file next to
  # the weights, and this unit restores it if a restore or a fresh volume lost it.
  systemd.services.kanbei-inference-models = {
    description = "Install the kanbei model manifest into the LUKS data volume";
    wantedBy = [ "multi-user.target" ];
    unitConfig.RequiresMountsFor = [ "/var/lib/kanbei" ];
    after = [ "local-fs.target" ];
    before = [
      "kanbei-chat.service"
      "kanbei-embeddings.service"
      "kanbei-rerank.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      UMask = "0027";
      path = [ pkgs.coreutils ];
    };
    script = ''
      set -euo pipefail
      install -d -m 0750 -o root -g ${group} ${modelsDir}
      install -d -m 0750 -o ${user} -g ${group} ${cacheDir}
      install -m 0644 ${manifestPath} ${modelsDir}/llama-models.json
    '';
  };

  # One gate for the three servers: the chat lane must not start against a card the driver
  # has not claimed yet (a cold passthrough probe can take a few seconds).
  systemd.services.kanbei-inference-gpu = {
    description = "Wait for the kanbei guest's passthrough RTX 3090";
    wantedBy = [ "multi-user.target" ];
    after = [
      "systemd-modules-load.service"
      "systemd-udev-settle.service"
    ];
    before = [ "kanbei-chat.service" ];
    unitConfig = {
      StartLimitIntervalSec = "10min";
      StartLimitBurst = 10;
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = "5s";
      TimeoutStartSec = "5min";
      ExecStart = gpuReady;
    };
  };

  systemd.services.kanbei-chat = {
    description = "Kanbei chat lane (Qwen3.8-27B, ${toString lanes.slots}-slot unified q8_0 KV)";
    wantedBy = [ "multi-user.target" ];
    after = [
      "kanbei-inference-models.service"
      "kanbei-inference-gpu.service"
    ];
    requires = [
      "kanbei-inference-models.service"
      "kanbei-inference-gpu.service"
    ];
    unitConfig = {
      RequiresMountsFor = [ "/var/lib/kanbei" ];
      StartLimitIntervalSec = "30min";
      StartLimitBurst = 5;
    };
    serviceConfig = commonHardening // {
      ExecStart = execStart (chatArgs { });
      User = user;
      Group = group;
      Restart = "always";
      RestartSec = "5s";
      # 14 GiB of weights stream from the LUKS volume through an 8 GiB guest on a cold start.
      TimeoutStartSec = "2h";
      TimeoutStopSec = "30s";
      ReadOnlyPaths = [ modelsDir ];
      ReadWritePaths = [ cacheDir ];
      Environment = [
        "HOME=${cacheDir}"
        "XDG_CACHE_HOME=${cacheDir}"
        "CUDA_CACHE_PATH=${cacheDir}/cuda"
      ];
    };
  };

  # Embeddings and reranking are CPU work: pinning them to physical cores keeps them off the
  # chat lane's vCPUs (the guest gets 8 vcpu = ${toString cpu.physicalCores} physical cores with SMT).
  systemd.services.kanbei-embeddings = {
    description = "Kanbei embeddings lane (Qwen3-Embedding-0.6B q8_0, last pooling)";
    wantedBy = [ "multi-user.target" ];
    after = [ "kanbei-inference-models.service" ];
    requires = [ "kanbei-inference-models.service" ];
    unitConfig = {
      RequiresMountsFor = [ "/var/lib/kanbei" ];
      StartLimitIntervalSec = "10min";
      StartLimitBurst = 5;
    };
    serviceConfig = commonHardening // {
      ExecStart = execStart (embeddingsArgs { });
      User = user;
      Group = group;
      Restart = "always";
      RestartSec = "5s";
      TimeoutStartSec = "10min";
      ReadOnlyPaths = [ modelsDir ];
      MemoryMax = "2G";
      MemoryHigh = "1500M";
    };
  };

  systemd.services.kanbei-rerank = {
    description = "Kanbei rerank lane (bge-reranker-v2-m3 q8_0)";
    wantedBy = [ "multi-user.target" ];
    after = [ "kanbei-inference-models.service" ];
    requires = [ "kanbei-inference-models.service" ];
    unitConfig = {
      RequiresMountsFor = [ "/var/lib/kanbei" ];
      StartLimitIntervalSec = "10min";
      StartLimitBurst = 5;
    };
    serviceConfig = commonHardening // {
      ExecStart = execStart (rerankArgs { });
      User = user;
      Group = group;
      Restart = "always";
      RestartSec = "5s";
      TimeoutStartSec = "10min";
      ReadOnlyPaths = [ modelsDir ];
      MemoryMax = "1536M";
      MemoryHigh = "1200M";
    };
  };

  # The eval renders exactly what the units run; `nix eval` reads this file instead of
  # re-deriving the pool from prose.
  environment.etc."kanbei/inference.json".text = builtins.toJSON inference.effective;

  assertions = [
    {
      assertion = budget.fits;
      message = "kanbei-inference: the ${toString lanes.poolTokens}-token q8_0 pool needs ${toString budget.totalMiB} MiB (weights + KV + recurrent state + overhead), more than the 3090's 24576 MiB";
    }
    {
      assertion = lanes.poolTokens >= lanes.longLane;
      message = "kanbei-inference: the pool (${toString lanes.poolTokens}) must fit one long lane (${toString lanes.longLane})";
    }
    {
      assertion = cpu.physicalCores * cpu.smt == cpu.vcpu;
      message = "kanbei-inference: the thread count must be the guest's physical cores (${toString cpu.physicalCores} x ${toString cpu.smt} = ${toString cpu.vcpu} vcpu)";
    }
    {
      # MTP is off: the chat file is the MTP-free quant and no --spec-* argument may appear.
      assertion = !(lib.any (a: lib.hasPrefix "--spec-" a) (chatArgs { }));
      message = "kanbei-inference: the chat lane must not enable speculative decoding (no --spec-* flags)";
    }
    {
      assertion = lib.all (port: port > 1024 && port < 65535) (lib.attrValues ports);
      message = "kanbei-inference: lane ports must be unprivileged";
    }
  ];
}
