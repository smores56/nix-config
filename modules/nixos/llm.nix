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

  # ik-llama fork supports gemma4-assistant architecture (MTP head for Gemma 4)
  # Built with gcc13Stdenv — GCC 14 is too strict for this codebase.
  # CUDAHOSTCXX forces nvcc to use GCC 13 host compiler (nvcc ignores stdenv).
  ik-llama = pkgs.gcc13Stdenv.mkDerivation {
    pname = "ik-llama-cpp";
    version = "ik-master";
    src = pkgs.fetchFromGitHub {
      owner = "ikawrakow";
      repo = "ik_llama.cpp";
      rev = "6b9de3dbaa21ae95ea80638e5ee836795cc48c93";
      hash = "sha256-ihzg0nomnn4eVCPcy4rcENIcbOAnYzfcJvd8gApzT0w=";
    };
    CUDAHOSTCXX = "${pkgs.gcc13Stdenv.cc}/bin/g++";
    postPatch = ''
      sed -i '1i#include <cstdint>' ggml/src/iqk/iqk_common.h
    '';
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
      cmake -B build -DGGML_CUDA=ON
    '';
    buildPhase = ''
      cmake --build build --config Release -j$(nproc)
    '';
    installPhase = ''
      cmake --install build --prefix $out
      mkdir -p $out/include
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
