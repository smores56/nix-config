{
  pkgs,
  aiProviders,
  ...
}:
let
  ports = import ../ports.nix;

  # DFlash2 copies the target's positions into its text-only draft KV cache, so
  # mtmd image chunks leave a gap and every image request 500s ("failed to
  # process mtmd chunk"). This is Sphinx-8's open PR against the same revision;
  # drop it when z-lab merges an equivalent fix.
  dflashVisionPatch = pkgs.fetchurl {
    url = "https://github.com/Sphinx-8/llama.cpp-dflash2-vision/commit/46d78b7fa5de4a6526c9b950a15d48682285f1d7.patch";
    hash = "sha256-uwOUSSOP+3tkc9VVzQhFE+YOoSBdrLeZ2kApoOD4W8A=";
  };

  llama-cpp = pkgs.stdenv.mkDerivation {
    pname = "llama-cpp";
    version = "dflash2-1deefcca";
    patches = [ dflashVisionPatch ];
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

  # Qwen3.8-27B RVN Heretic IQ4_XS. KV exists only on the 16 gated attention layers,
  # so long context is cheap; IQ4_XS leaves room for the drafter's full-context KV at
  # 200K on the 3090.
  mainModel = pkgs.fetchurl {
    url = "https://huggingface.co/0bserverx/Qwen3.8-27B-Heretic-Abliterated-Uncensored-GGUF/resolve/main/RVN-IQ4_XS-multilingual.gguf";
    hash = "sha256-thWFa6SmINs74AT/XlxGs6bFw6F9JHvvLPbL4coyWqQ=";
  };

  # DFlash2 block-diffusion drafter (z-lab); Q2_K suits a 24 GB card.
  draftModel = pkgs.fetchurl {
    url = "https://huggingface.co/analogalok/Qwen3.8-27B-DFlash2-Q2_K-GGUF/resolve/main/Qwen3.8-27B-DFlash2-Q2_K.gguf";
    hash = "sha256-u7zVtmtXH0OP8gGBhGSONyEaHYLEktMoNK8toscZN1U=";
  };

  # The vision encoder: the Heretic finetune only abliterates text layers, so the
  # base checkpoint's qwen3vl projector matches it. Without it the server reports
  # modalities.vision=false and rejects image parts.
  mmprojModel = pkgs.fetchurl {
    url = "https://huggingface.co/unsloth/Qwen3.8-27B-GGUF/resolve/main/mmproj-F16.gguf";
    hash = "sha256-y7hBqe4GNrLsFy9buN8uqN/rAekP58YSZYHWYqC05D4=";
  };

  # RTX 3090 VRAM budget (24,576 MiB):
  #   Model weights (RVN IQ4_XS):  14,385 MiB
  #   DFlash2 drafter (Q2_K):         672 MiB
  #   Runtime/CUDA overhead:         1,200 MiB
  #   KV (target q4_0 + drafter, 200K ctx): ~7,500 MiB
  #   Total: ~23.2 GiB — 200K is the ceiling; larger ctx needs lighter weights.
  #   The 927 MiB vision projector stays on the CPU (see no-mmproj-offload).
in
{
  config = {
    # The host serves the model around the clock, so it must never suspend.
    systemd.sleep.settings.Sleep = {
      AllowSuspend = false;
      AllowHibernation = false;
      AllowHybridSleep = false;
      AllowSuspendThenHibernate = false;
    };

    services.llama-cpp = {
      enable = true;
      package = llama-cpp;
      settings = {
        # Loopback only: the Cloudflare Tunnel proxies llm.<domain> to it, and
        # the tunnel's Access app is the only way in.
        host = "127.0.0.1";
        port = ports.llm;
        alias = aiProviders.smortress.models.qwen38.id;
        model = mainModel;
        n-gpu-layers = 99;
        ctx-size = 200192;
        cache-type-k = "q4_0";
        cache-type-v = "q4_0";
        parallel = 1;
        # /slots can return the last prompt, and the agent VM reaches this port; secret-review
        # sends unredacted findings here.
        no-slots = true;
        cont-batching = true;
        flash-attn = "on";
        spec-type = "draft-dflash";
        spec-draft-n-max = 3;
        model-draft = draftModel;
        n-gpu-layers-draft = 99;
        mmproj = mmprojModel;
        # The card sits at ~20.5 GiB before vision; keeping the encoder on the
        # CPU leaves the projector and its compute buffer out of VRAM.
        no-mmproj-offload = true;
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
