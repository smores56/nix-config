# Canonical provider specs for maki's providers.toml. Injected as a single
# `aiProviders` attrset so consumers never import individual providers.
#
# Models are authored via mkModel into maki's providers.toml model shape (see
# modules/features/ai/maki/default.nix).
{ lib, ... }:
let
  # The retired provider scripts borrowed maki's llama-cpp adapter, which
  # spells thinking as `thinking_budget_tokens` (0 = off, -1 = unbounded).
  # A custom openai-protocol entry only thinks through declared
  # thinking_fields, so spell the same field; every effort level snaps up
  # to `max`.
  budgetThinking = {
    off.thinking_budget_tokens = 0;
    adaptive.thinking_budget_tokens = -1;
    max.thinking_budget_tokens = -1;
  };

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
      # A custom openai-protocol entry reports no vision unless declared, so
      # image input and view_image stay off without it.
      supports_vision = vision;
      pricing_input = prompt;
      pricing_output = completion;
      pricing_cache_write = 0;
      pricing_cache_read = cacheRead;
    }
    // lib.optionalAttrs reasoning { thinking_fields = budgetThinking; };

  # ── Neuralwatt ────────────────────────────────────────────────────────────
  # No thinking pinning: maki's always_thinking="max" (init.lua) drives
  # reasoning depth.
  neuralwatt = {
    providerId = "neuralwatt";
    baseUrl = "https://api.neuralwatt.com/v1";
    keyEnv = "NEURALWATT_API_KEY";
    # deepseek-v4.1-flash serves a 256K window (native 1M context). Both models
    # report vision in the /v1/models capabilities, and maki only learns that
    # from this flag.
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
  # Local network provider; no auth needed. models.qwen38
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
    # Reached only when the host resolves into the tailnet (100.64.0.0/10) —
    # a disconnected tailnet must not fall back to untrusted local DNS. The
    # gate lives in maki's fish wrapper (maki/default.nix).
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
