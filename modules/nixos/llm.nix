{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles;
  model = {
    repo = "unsloth/Qwen3.6-27B-GGUF";
    file = "Qwen3.6-27B-Q4_K_M.gguf";
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
        "-ngl"
        "99"
        "-c"
        "131072"
        "--cache-type-k"
        "q4_0"
        "--cache-type-v"
        "q4_0"
      ];
    };

    systemd.services.llama-cpp = {
      requires = [ "nvidia-uvm.service" ];
      after = [ "nvidia-uvm.service" ];
      serviceConfig = {
        TimeoutStartSec = "1h";
      };
    };

    systemd.sleep.settings.Sleep = {
      AllowSuspend = false;
      AllowHibernation = false;
      AllowHybridSleep = false;
      AllowSuspendThenHibernate = false;
    };
  };
}
