# Lane, flag and VRAM facts for the kanbei inference lanes (smores56/sdlc#585, part of #509).
#
# One attrset holds the whole pool shape so the NixOS module, `/etc/kanbei/inference.json` and
# `nix eval` all render the same numbers. Pure data: no `pkgs`, no options.
#
# Shape: llama.cpp's server cannot give one slot 128k and three slots 32k in a single process
# (there is one `-c` and one `-np`). The closest supported shape is a unified KV pool shared by
# four slots with a uniform per-slot cap; docs/kanbei-inference.md explains what each lane gets.
{
  lib,
}:
let
  # unsloth/Qwen3.8-27B-GGUF `text_config`: qwen3_5, 64 layers, every 4th full attention, 4 KV
  # heads of 256, 48 linear-attention layers with 48x128 values and 128-wide keys, f32 state.
  arch = {
    layers = 64;
    fullAttentionInterval = 4;
    fullAttentionLayers = 16;
    kvHeads = 4;
    headDim = 256;
    linearLayers = 48;
    linearValueHeads = 48;
    linearValueHeadDim = 128;
    linearKeyHeadDim = 128;
    # mamba_ssm_dtype = float32 in the checkpoint.
    linearStateBytes = 4;
    trainContext = 262144;
  };

  # Block-quantised KV: q8_0 is 32 int8 values plus one f16 scale per 32 elements.
  quant = {
    q8_0 = {
      blockElements = 32;
      blockBytes = 34;
    };
    f16 = {
      blockElements = 1;
      blockBytes = 2;
    };
  };

  mib = bytes: builtins.div (bytes + 1048575) 1048576;

  manifest = builtins.fromJSON (builtins.readFile ./kanbei-models.json);

  modelsDir = manifest.destination;
  cacheDir = "/var/lib/kanbei/kv-cache";

  modelSpec =
    name:
    manifest.models.${name}
    // {
      path = "${modelsDir}/${manifest.models.${name}.file}";
      sizeMiB = mib manifest.models.${name}.size;
    };

  # KV is stored only on the full-attention layers; the 48 linear-attention layers keep a
  # recurrent state instead, whose size is per sequence, not per token.
  kvBytesPerToken =
    quantName:
    let
      q = quant.${quantName};
    in
    builtins.div (
      2 * arch.fullAttentionLayers * arch.kvHeads * arch.headDim * q.blockBytes
    ) q.blockElements;

  linearStateBytesPerSlot =
    arch.linearLayers
    * arch.linearValueHeads
    * arch.linearValueHeadDim
    * arch.linearKeyHeadDim
    * arch.linearStateBytes;

  poolTokens = 163840;
  longLane = 131072;
  shortLane = 32768;
  perSlotCap = 131072;

  kvPoolMiB = mib (poolTokens * kvBytesPerToken "q8_0");
  nominalTokens = longLane + 3 * shortLane;
  nominalKvMiB = mib (nominalTokens * kvBytesPerToken "q8_0");
  recurrentStateMiB = mib (4 * linearStateBytesPerSlot);
  weightsMiB = (modelSpec "chat").sizeMiB;
  runtimeOverheadMiB = 1200;

  totalMiB = weightsMiB + runtimeOverheadMiB + kvPoolMiB + recurrentStateMiB;
  nominalTotalMiB = weightsMiB + runtimeOverheadMiB + nominalKvMiB + recurrentStateMiB;

  # Unified pool: breadth-first sharing, not a reservation. The long lane only gets its cap
  # while fewer than two short lanes are resident (163840 - 2*32768 = 98304).
  longLaneWith = shortResident: lib.min perSlotCap (poolTokens - shortResident * shortLane);
  shortLaneShare = longResident: builtins.div (poolTokens - longResident * longLane) 3;

  lanes = {
    slots = 4;
    kvType = "q8_0";
    kvBytesPerToken = kvBytesPerToken "q8_0";
    # Upstream master spells the per-slot ceiling `--kv-unified-per-slot N`; the pinned fork
    # (1deefcca) predates that flag and only has `-kvu/--kv-unified`, where the shared pool is
    # the ceiling. `perSlotCap` is what the lane config asks for.
    inherit perSlotCap;
    perSlotCapSupported = false;
    inherit
      poolTokens
      longLane
      shortLane
      nominalTokens
      ;
    inherit longLaneWith shortLaneShare;
  };

  budget = {
    gpuMiB = 24576;
    inherit
      weightsMiB
      runtimeOverheadMiB
      kvPoolMiB
      recurrentStateMiB
      totalMiB
      ;
    headroomMiB = 24576 - totalMiB;
    fits = totalMiB <= 24576;
  };

  # The 224k counterfactual, kept next to the configured pool so the trade-off is auditable.
  budgetAtNominal = budget // {
    kvPoolMiB = nominalKvMiB;
    totalMiB = nominalTotalMiB;
    headroomMiB = 24576 - nominalTotalMiB;
    fits = nominalTotalMiB <= 24576;
  };

  # The guest gets 8 vcpu from an SMT host, so the CPU servers ask for physical cores only.
  cpu = {
    vcpu = 8;
    smt = 2;
    physicalCores = 4;
  };

  ports = {
    chat = 8090;
    embeddings = 8091;
    rerank = 8092;
  };

  chatArgs =
    {
      modelPath ? (modelSpec "chat").path,
      slotSavePath ? cacheDir,
    }:
    [
      "--model"
      modelPath
      "--alias"
      "kanbei-chat"
      # Tool calling: nanobot sends a `tools` array, and only the checkpoint's own Jinja
      # template emits the tool-call tokens the server can parse back into `tool_calls`.
      "--jinja"
      # No NIC in the guest: loopback is the only listener, and the future vsock relay is the
      # only way to reach it from the host.
      "--host"
      "127.0.0.1"
      "--port"
      (toString ports.chat)
      "--ctx-size"
      (toString poolTokens)
      "--parallel"
      (toString 4)
      # Unified KV pool shared by the four slots; keys and values are q8_0.
      "--kv-unified"
      "--cache-type-k"
      "q8_0"
      "--cache-type-v"
      "q8_0"
      "--flash-attn"
      "on"
      "--n-gpu-layers"
      "all"
      # Hybrid prefix reuse: checkpoints of the state that cannot be rolled back, at most 8 per
      # slot and at least 8k apart. The RAM prompt cache keeps idle slots for the next request;
      # 1 GiB caps what four idle slots may pin now that the guest has 6 GiB of RAM.
      "--ctx-checkpoints"
      "8"
      "--checkpoint-min-step"
      "8192"
      "--cache-ram"
      "1024"
      "--cache-idle-slots"
      "--slot-save-path"
      slotSavePath
      "--no-context-shift"
      "--cont-batching"
      "--metrics"
    ];

  embeddingsArgs =
    {
      modelPath ? (modelSpec "embeddings").path,
    }:
    [
      "--model"
      modelPath
      "--alias"
      "kanbei-embeddings"
      "--host"
      "127.0.0.1"
      "--port"
      (toString ports.embeddings)
      "--embeddings"
      "--pooling"
      "last"
      # ~940 MiB of f16 KV at 8k plus the 610 MiB model; the unit's cap assumes this.
      "--ctx-size"
      "8192"
      "--batch-size"
      "2048"
      "--ubatch-size"
      "512"
      "--parallel"
      "4"
      "--threads"
      (toString cpu.physicalCores)
      "--threads-batch"
      (toString cpu.physicalCores)
      "--n-gpu-layers"
      "0"
    ];

  rerankArgs =
    {
      modelPath ? (modelSpec "rerank").path,
    }:
    [
      "--model"
      modelPath
      "--alias"
      "kanbei-rerank"
      "--host"
      "127.0.0.1"
      "--port"
      (toString ports.rerank)
      # No --pooling: the bge reranker GGUF carries rank pooling in its metadata.
      "--reranking"
      "--ctx-size"
      "4096"
      "--batch-size"
      "2048"
      "--ubatch-size"
      "512"
      "--parallel"
      "4"
      "--threads"
      (toString cpu.physicalCores)
      "--threads-batch"
      (toString cpu.physicalCores)
      "--n-gpu-layers"
      "0"
    ];

  effective = {
    lanes = {
      inherit (lanes)
        slots
        kvType
        kvBytesPerToken
        perSlotCap
        perSlotCapSupported
        poolTokens
        longLane
        shortLane
        nominalTokens
        ;
    };
    inherit
      budget
      budgetAtNominal
      cpu
      ports
      modelsDir
      cacheDir
      ;
    args = {
      chat = chatArgs { };
      embeddings = embeddingsArgs { };
      rerank = rerankArgs { };
    };
    # What the long lane actually gets, in tokens.
    longLaneActual = {
      alone = longLaneWith 0;
      withOneShort = longLaneWith 1;
      withTwoShorts = longLaneWith 2;
      withThreeShorts = longLaneWith 3;
    };
    shortLaneActual = shortLaneShare 1;
  };
in
{
  inherit
    arch
    budget
    budgetAtNominal
    cacheDir
    chatArgs
    cpu
    effective
    embeddingsArgs
    kvBytesPerToken
    lanes
    modelsDir
    ports
    rerankArgs
    ;
}
