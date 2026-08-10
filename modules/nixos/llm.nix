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

  # HauhauCS "Balanced" — uncensored (0/465 refusals) build of Google's QAT
  # checkpoint, quantized Q4_K_M.  QAT-trained at 4-bit, so Q4_K_M is the
  # sweet spot (higher quants add size without quality).
  mainModel = pkgs.fetchurl {
    url = "https://huggingface.co/HauhauCS/Gemma4-31B-QAT-Uncensored-HauhauCS-Balanced-MTP/resolve/main/Gemma4-31B-QAT-Uncensored-HauhauCS-Balanced-Q4_K_M.gguf";
    hash = "sha256-1ny7kx30gvpis7dn3mk0s8anw7vk1camjp22k1592jqsc2g7yrki";
  };

  # MTP draft model — Unsloth's MTP head (280 MB), bundled with the HauhauCS release.
  mtpModel = pkgs.fetchurl {
    url = "https://huggingface.co/HauhauCS/Gemma4-31B-QAT-Uncensored-HauhauCS-Balanced-MTP/resolve/main/mtp-gemma-4-31B-it.gguf";
    hash = "sha256-0qhv83ga61nnpvb974acklgkdv6sgqdvqjqih28470jrzj1ybi5m";
  };

  # RTX 3090 VRAM budget (24,576 MiB):
  #   Model weights (Q4_K_M): 17,821 MiB
  #   MTP drafter:               267 MiB
  #   Runtime/CUDA overhead:   1,200 MiB
  #   KV cache budget:         5,288 MiB → ~128K ctx with Q4_0 KV
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
        # HauhauCS-recommended sampling (README): dialed in for this build
        "--temp"
        "0.6"
        "--top-k"
        "64"
        "--top-p"
        "0.9"
        "--min-p"
        "0.05"
        "--repeat-penalty"
        "1.1"
      ];
    };

    systemd.services.llama-cpp = {
      requires = [ "nvidia-uvm.service" ];
      after = [ "nvidia-uvm.service" ];
      serviceConfig.TimeoutStartSec = "1h";
    };
  };
}
