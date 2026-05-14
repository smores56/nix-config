{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles;
  models = {
    ${cfg.defaultModel} = {
      repo = "bartowski/google_gemma-4-26B-A4B-it-GGUF";
      file = "google_gemma-4-26B-A4B-it-Q4_K_M.gguf";
    };
    ${cfg.altModel} = {
      repo = "unsloth/Qwen3.6-27B-GGUF";
      file = "Qwen3.6-27B-Q4_K_M.gguf";
    };
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
      modelsPreset = lib.mapAttrs (name: m: {
        alias = name;
        hf-repo = m.repo;
        hf-file = m.file;
      }) models;
      extraFlags = [
        "-ngl"
        "99"
        "-c"
        "131072"
      ];
    };

    systemd.services.llama-cpp.serviceConfig = {
      TimeoutStartSec = "1h";
    };

    systemd.sleep.settings.Sleep = {
      AllowSuspend = false;
      AllowHibernation = false;
      AllowHybridSleep = false;
      AllowSuspendThenHibernate = false;
    };
  };
}
