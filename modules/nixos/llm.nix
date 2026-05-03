{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles;
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
      modelsPreset = {
        ${cfg.defaultModel} = {
          hf-repo = "bartowski/google_gemma-4-26B-A4B-it-GGUF";
          hf-file = "google_gemma-4-26B-A4B-it-Q4_K_M.gguf";
        };
        ${cfg.altModel} = {
          hf-repo = "unsloth/Qwen3.6-27B-GGUF";
          hf-file = "Qwen3.6-27B-Q4_K_M.gguf";
        };
      };
      extraFlags = [
        "-ngl"
        "99"
        "-c"
        "32768"
      ];
    };
  };
}
