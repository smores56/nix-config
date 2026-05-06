{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles;
  modelsDir = "/var/cache/llama-cpp/models";
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
  downloadModels = pkgs.writeShellScript "download-llm-models" (
    "mkdir -p ${modelsDir}\n"
    + lib.concatStringsSep "\n" (
      lib.mapAttrsToList (_: m: ''
        [ -f "${modelsDir}/${m.file}" ] || {
          echo "Downloading ${m.file}..."
          ${pkgs.curl}/bin/curl -fL -C - -o "${modelsDir}/${m.file}.part" \
            "https://huggingface.co/${m.repo}/resolve/main/${m.file}"
          mv "${modelsDir}/${m.file}.part" "${modelsDir}/${m.file}"
        }
      '') models
    )
  );
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
      modelsPreset = lib.mapAttrs (_: m: {
        model = "${modelsDir}/${m.file}";
      }) models;
      extraFlags = [
        "-ngl"
        "99"
        "-c"
        "131072"
      ];
    };

    systemd.services.llama-cpp.serviceConfig = {
      ExecStartPre = "${downloadModels}";
      TimeoutStartSec = "1h";
    };
  };
}
