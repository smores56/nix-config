{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles;

  llama-cpp = pkgs.stdenv.mkDerivation {
    pname = "llama-cpp";
    version = "gemma4-mtp-efd651a";
    src = pkgs.fetchFromGitHub {
      owner = "am17an";
      repo = "llama.cpp";
      rev = "efd651a8ef2cd13d6c7bb22358659fb64f9e3b18";
      hash = "sha256-Hay2cs4lt/oqzP9BpZ+oy3YBYvYnimm5F5XgS7o20k0=";
    };
    nativeBuildInputs = with pkgs; [
      cmake
      ninja
      pkg-config
      cudaPackages.cuda_nvcc
      autoAddDriverRunpath
    ];
    buildInputs = with pkgs; [
      openssl
      curl
      cudaPackages.cuda_cudart
      cudaPackages.libcublas
    ];
    configurePhase = ''
      echo "unknown" > COMMIT
      cmake -B build \
        -DGGML_CUDA=ON \
        -DGGML_AVX2=ON \
        -DGGML_FMA=ON \
        -DGGML_F16C=ON \
        -DLLAMA_CURL=ON \
        -DCMAKE_CUDA_ARCHITECTURES="86" \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DLLAMA_BUILD_EXAMPLES=ON
    '';
    buildPhase = ''
      cmake --build build --config Release -j$(nproc)
    '';
    installPhase = ''
      cmake --install build --prefix $out
    '';
  };

  mainModel = pkgs.fetchurl {
    url = "https://huggingface.co/unsloth/gemma-4-31B-it-qat-GGUF/resolve/main/gemma-4-31B-it-qat-UD-Q4_K_XL.gguf";
    hash = "sha256-kYinEFVVDx5guHXQK3q7Y2JawRtKbxSNayKzsouj0zU=";
  };

  # MTP draft model — MTP head weights quantized Q8_0 (514 MB).  Nix-fetched.
  mtpModel = pkgs.fetchurl {
    url = "https://huggingface.co/unsloth/gemma-4-31B-it-GGUF/resolve/main/MTP/gemma-4-31B-it-MTP-Q8_0.gguf";
    hash = "sha256-WuiwEXvtYB6JJMYwW9WwWF3jYdUfDncJG8tCUs8fJ94=";
  };

  # RTX 3090 VRAM budget (24,576 MiB):
  #   Model weights (Q4_K_XL): 16,487 MiB
  #   MTP drafter (Q8_0):         490 MiB
  #   Runtime/CUDA overhead:    1,200 MiB
  #   KV cache budget:          6,543 MiB → ~128K ctx with Q4_0 KV
  #   Actual max ctx: ~140K (num_global_kv_heads=16 assumption)
  #   Push -c higher if stable; 262K only if gkv≤8
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
      package = llama-cpp;
      host = "0.0.0.0";
      port = 8081;
      extraFlags = [
        "--alias"
        cfg.defaultModel
        "--model"
        "${mainModel}"
        "-ngl"
        "99"
        "-c"
        "128000"
        "--cache-type-k"
        "q4_0"
        "--cache-type-v"
        "q4_0"
        "-np"
        "1"
        "--cont-batching"
        "--flash-attn"
        "on"
        "--spec-type"
        "draft-mtp"
        "--spec-draft-n-max"
        "2"
        "--spec-draft-p-min"
        "0.5"
        "--model-draft"
        "${mtpModel}"
        "-ngld"
        "99"
        "--reasoning-format"
        "deepseek"
      ];
    };

    systemd.services.llama-cpp = {
      requires = [ "nvidia-uvm.service" ];
      after = [ "nvidia-uvm.service" ];
      serviceConfig.TimeoutStartSec = "1h";
    };
  };
}
