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
  # 2 slots @ 100K = 200000 total ctx: 4.59 GB KV → 23.39 GB total, 1.15 GB headroom
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
        "200000"
        "--cache-type-k"
        "q4_0"
        "--cache-type-v"
        "q4_0"
        "-np"
        "2"
        "--cont-batching"
        "--spec-type"
        "draft-mtp"
        "--hf-repo-draft"
        "unsloth/gemma-4-31B-it-GGUF"
        "--hf-file-draft"
        "MTP/gemma-4-31B-it-MTP-Q8_0.gguf"
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
