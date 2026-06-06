{
  config,
  lib,
  pkgs,
  ...
}:
let
  # VRAM: 17.3GB(model) + 1.5GB(scratch) + KV_cache
  # KV: 50 sliding (1024 window) × 4608 B/t + 10 global × 2304 × ctx × slots
  # 2 slots @ 100K ctx: 4.73 GB KV → 23.53 GB total, 0.47 GB headroom
  # 2 slots @  75K ctx: 3.66 GB KV → 22.46 GB total, 1.54 GB headroom
  # 3 slots @  50K ctx: 3.88 GB KV → 22.68 GB total, 1.32 GB headroom
  # 4 slots @  32K ctx: 3.69 GB KV → 22.49 GB total, 1.51 GB headroom
  cfg = config.dotfiles;
  model = {
    repo = "unsloth/gemma-4-31B-it-qat-GGUF";
    file = "gemma-4-31B-it-qat-UD-Q4_K_XL.gguf";
  };
in
{
  config = lib.mkIf cfg.llm {
    assertions = [
      {
        assertion = cfg.nvidia;
        message = "llm requires nvidia = true for CUDA support";
      }
    ];

    services.llama-cpp = {
      enable = true;
      package = pkgs.llama-cpp.override { cudaSupport = true; };
      host = "0.0.0.0";
      port = 8080;
      openFirewall = false;
      extraFlags = [
        "--alias"
        cfg.defaultModel
        "--hf-repo"
        model.repo
        "--hf-file"
        model.file
        "--no-mmproj"
        "-ngl"
        "99"
        "-c"
        "102400"
        "--cache-type-k"
        "q4_0"
        "--cache-type-v"
        "q4_0"
        "-np"
        "2"
        "--cont-batching"
      ];
    };
    systemd.services.llama-cpp = {
      requires = [ "nvidia-uvm.service" ];
      after = [ "nvidia-uvm.service" ];
      serviceConfig = {
        TimeoutStartSec = "1h";
      };
    };

  };
}
