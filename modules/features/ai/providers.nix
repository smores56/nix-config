# Canonical provider specs for maki provider scripts. Injected as a single
# `aiProviders` attrset so consumers never import individual providers.
#
# Models are authored via mkModel into maki's provider-script shape (see
# modules/features/ai/maki/default.nix).
_:
let
  # Prices are $/M tokens. reasoning defaults true and write-cache credit is
  # 0 for every model, so specs only state what differs.
  mkModel =
    {
      id,
      context,
      output,
      reasoning ? true,
      vision ? false,
      prompt,
      completion,
      cacheRead ? 0,
    }:
    {
      inherit id;
      context_window = context;
      max_output_tokens = output;
      supports_thinking = reasoning;
      # maki's base llama-cpp spec is family Generic, which reports no vision, so
      # a script provider has to declare it or view_image/image input stay off.
      supports_vision = vision;
      pricing = {
        input = prompt;
        output = completion;
        cache_write = 0;
        cache_read = cacheRead;
      };
    };

  # ── Neuralwatt ────────────────────────────────────────────────────────────
  # No thinking pinning: maki's always_thinking="max" (init.lua) drives
  # reasoning depth.
  neuralwatt = {
    providerId = "neuralwatt";
    baseUrl = "https://api.neuralwatt.com/v1";
    keyEnv = "NEURALWATT_API_KEY";
    # deepseek-v4.1-flash serves a 256K window (native 1M context). Both models
    # report vision in the /v1/models capabilities, and maki only learns that
    # from this flag: the provider script's llama-cpp base has no vision of its
    # own, so image input and the view_image tool stay off without it.
    makiModels = map mkModel [
      {
        id = "deepseek-v4.1-flash";
        context = 262144;
        output = 65536;
        vision = true;
        prompt = 0.15;
        completion = 0.60;
        cacheRead = 0.02;
      }
      {
        id = "qwen-3.8-27b";
        context = 262144;
        output = 32768;
        vision = true;
        prompt = 0.45;
        completion = 3.20;
        cacheRead = 0.25;
      }
    ];
  };

  # ── Smortress ─────────────────────────────────────────────────────────────
  # Local network provider; no auth needed (keyEnv = null). models.qwen38
  # feeds the dotfiles default model in options.nix.
  qwen38Model = mkModel {
    id = "qwen3.8-27b";
    context = 200192;
    output = 200192;
    prompt = 0.0;
    completion = 0.0;
  };

  smortress = {
    providerId = "smortress";
    models.qwen38 = qwen38Model;
    baseUrl = "http://smortress:8081/v1";
    keyEnv = null;
    # Offered only when the host resolves into the tailnet (100.64.0.0/10) —
    # a disconnected tailnet must not fall back to untrusted local DNS.
    tailnetOnly = true;
    makiModels = [ qwen38Model ];
  };
in
{
  _module.args.aiProviders = {
    inherit
      neuralwatt
      smortress
      ;
  };
}
