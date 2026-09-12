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
      prompt,
      completion,
      cacheRead ? 0,
    }:
    {
      inherit id;
      context_window = context;
      max_output_tokens = output;
      supports_thinking = reasoning;
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
    # All preview models; qwen-3.8-27b is absent from the public /v1/models
    # scope. deepseek-v4.1-flash serves a 256K window (native 1M context).
    makiModels = map mkModel [
      {
        id = "deepseek-v4.1-flash";
        context = 262144;
        output = 65536;
        prompt = 0.15;
        completion = 0.60;
        cacheRead = 0.02;
      }
      {
        id = "qwen-3.8-27b";
        context = 262144;
        output = 32768;
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
