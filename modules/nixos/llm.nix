{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles;

  model = {
    repo = "unsloth/gemma-4-31B-it-qat-GGUF";
    file = "gemma-4-31B-it-qat-UD-Q4_K_XL.gguf";
  };

  # ik-llama fork supports gemma4-assistant (MTP) architecture — mainline doesn't.
  # GCC 14 is too strict for this codebase; force GCC 13 + force-include cstdint.
  # Build only llama-server target to avoid iqk quantize compilation units
  # that rely on AVX2 intrinsics stripped by NIX_ENFORCE_NO_NATIVE.
  ik-llama = pkgs.gcc13Stdenv.mkDerivation {
    pname = "ik-llama-cpp";
    version = "ik-master";
    src = pkgs.fetchFromGitHub {
      owner = "ikawrakow";
      repo = "ik_llama.cpp";
      rev = "6b9de3dbaa21ae95ea80638e5ee836795cc48c93";
      hash = "sha256-ihzg0nomnn4eVCPcy4rcENIcbOAnYzfcJvd8gApzT0w=";
    };
    NIX_ENFORCE_NO_NATIVE = "0";
    CUDAHOSTCXX = "${pkgs.gcc13Stdenv.cc}/bin/g++";
    nativeBuildInputs = with pkgs; [
      cmake
      ninja
      pkg-config
      cudaPackages.cuda_nvcc
      autoAddDriverRunpath
    ];
    buildInputs = with pkgs; [
      openssl
      cudaPackages.cuda_cudart
      cudaPackages.libcublas
    ];
    configurePhase = ''
      echo "unknown" > COMMIT
      cmake -B build \
        -DGGML_CUDA=ON \
        -DLLAMA_BUILD_EXAMPLES=ON \
        -DCMAKE_CXX_FLAGS="-include cstdint"
    '';
    buildPhase = ''
      cmake --build build --target llama-server --config Release -j$(nproc)
    '';
    installPhase = ''
      mkdir -p $out/bin $out/include
      cp build/bin/llama-server $out/bin/
      cp include/llama.h $out/include/
    '';
    outputs = [
      "out"
      "dev"
    ];
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
      package = ik-llama;
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
        "unsloth/gemma-4-31B-it-GGUF:MTP/gemma-4-31B-it-MTP-Q8_0.gguf"
        "--spec-draft-ngl"
        "99"
        "--reasoning-format"
        "none"
      ];
    };

    systemd.services.llama-cpp = {
      requires = [ "nvidia-uvm.service" ];
      after = [ "nvidia-uvm.service" ];
      serviceConfig.TimeoutStartSec = "1h";
    };
  };
}
