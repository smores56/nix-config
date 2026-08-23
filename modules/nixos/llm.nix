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
    version = "dflash2-1deefcca";
    src = pkgs.fetchFromGitHub {
      owner = "z-lab";
      repo = "llama.cpp-fork";
      rev = "1deefcca395743049c3820ab8f9b15043f3e9446";
      hash = "sha256-3onl5XEYTTmXeLiv8/JHHMf4rKiPzGnYkJBdAM41Xho=";
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

  # Qwen3.8-27B RVN Heretic — 0bserverx's double-refined abliteration, IQ4_XS
  # multilingual. KL 0.0085 vs base keeps DFlash2 drafter acceptance near-full.
  # KV cache exists only on the 16 gated attention layers, so long context is
  # cheap; IQ4_XS keeps weights light enough for the drafter's full-context KV
  # at 200K on the 3090.
  mainModel = pkgs.fetchurl {
    url = "https://huggingface.co/0bserverx/Qwen3.8-27B-Heretic-Abliterated-Uncensored-GGUF/resolve/main/RVN-IQ4_XS-multilingual.gguf";
    hash = "sha256-thWFa6SmINs74AT/XlxGs6bFw6F9JHvvLPbL4coyWqQ=";
  };

  # DFlash2 block-diffusion drafter (z-lab, llama.cpp PR #27342). Q2_K is
  # analogalok's 24 GB-card tuning (~705 MB; ~400 MB lighter than Q4_K_M).
  draftModel = pkgs.fetchurl {
    url = "https://huggingface.co/analogalok/Qwen3.8-27B-DFlash2-Q2_K-GGUF/resolve/main/Qwen3.8-27B-DFlash2-Q2_K.gguf";
    hash = "sha256-u7zVtmtXH0OP8gGBhGSONyEaHYLEktMoNK8toscZN1U=";
  };

  # RTX 3090 VRAM budget (24,576 MiB):
  #   Model weights (RVN IQ4_XS):  14,385 MiB
  #   DFlash2 drafter (Q2_K):         672 MiB
  #   Runtime/CUDA overhead:         1,200 MiB
  #   KV (target q4_0 + drafter, 200K ctx): ~7,500 MiB
  #     (measured on 24 GB cards: 23.9 GB total at 170K with Q4_K_XL weights;
  #     the drafter tracks the full context, so it dominates the KV budget)
  #   Total: ~23.2 GiB — 200K is the ceiling; larger ctx needs lighter weights
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
      settings = {
        host = "0.0.0.0";
        port = 8081;
        alias = cfg.defaultModel;
        model = mainModel;
        n-gpu-layers = 99;
        ctx-size = 200192;
        cache-type-k = "q4_0";
        cache-type-v = "q4_0";
        parallel = 1;
        cont-batching = true;
        flash-attn = "on";
        spec-type = "draft-dflash";
        spec-draft-n-max = 3;
        model-draft = draftModel;
        n-gpu-layers-draft = 99;
        reasoning-format = "deepseek";
        # Qwen3.8 model-card sampling (thinking mode; non-thinking: 0.7/0.8,
        # presence-penalty 1.5)
        temp = 1.0;
        top-k = 20;
        top-p = 0.95;
        min-p = 0.0;
        repeat-penalty = 1.0;
      };
    };

    systemd.services.llama-cpp = {
      requires = [ "nvidia-uvm.service" ];
      after = [ "nvidia-uvm.service" ];
      serviceConfig.TimeoutStartSec = "1h";
    };
  };
}
