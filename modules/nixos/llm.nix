{
  config,
  lib,
  pkgs,
  ...
}:
let
  # VRAM: 17.3GB(model) + 1.5GB(scratch) + KV_cache
  # KV = 50 sliding × 4608 + 10 global × 2304 × ctx_total
  # KV: 50×4608 = 225 KB (sliding fixed) + 23,040 B × ctx_total
  # 2 slots @ 131K = 262144 total ctx: 5.49 GB KV → 23.78 GB total, 800 MB headroom
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
      port = 8081;
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
        "262144"
        "--cache-type-k"
        "q4_0"
        "--cache-type-v"
        "q4_0"
        "-np"
        "2"
        "--cont-batching"
        "--reasoning-format"
        "none"
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
