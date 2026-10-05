# Canonical provider specs for maki's providers.toml. Injected as a single
# `aiProviders` attrset so consumers never import individual providers.
#
# Models are authored via mkModel into maki's providers.toml model shape (see
# modules/features/ai/maki/default.nix).
{ lib, ... }:
let
  # The retired provider scripts borrowed maki's llama-cpp adapter, which
  # spells thinking as `thinking_budget_tokens`: 0 off, -1 adaptive, and for
  # an effort level its percent of half the output window (floor 1024). A
  # custom openai-protocol entry only thinks through declared thinking_fields,
  # so declare every level with the budget the adapter would have sent.
  minThinkingBudget = 1024;
  effortPercents = {
    minimal = 10;
    low = 20;
    medium = 40;
    high = 60;
    xhigh = 80;
    max = 100;
  };
  budgetThinking =
    output:
    let
      maxBudget = lib.max (output / 2) minThinkingBudget;
      levelBudget = pct: lib.max minThinkingBudget (maxBudget * pct / 100);
    in
    {
      off.thinking_budget_tokens = 0;
      adaptive.thinking_budget_tokens = -1;
    }
    // lib.mapAttrs (_: pct: { thinking_budget_tokens = levelBudget pct; }) effortPercents;

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
    // lib.optionalAttrs reasoning { thinking_fields = budgetThinking output; };

  # ── Neuralwatt ────────────────────────────────────────────────────────────
  # No per-model effort pinning: maki's always_thinking="max" (init.lua)
  # picks the level, and mkModel's thinking_fields spell its budget.
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
    host = "smortress";
    baseUrl = "http://${smortress.host}:8081/v1";
    # Reached only when the host resolves into the tailnet (100.64.0.0/10) —
    # a disconnected tailnet must not fall back to untrusted local DNS. The
    # gate lives in maki's PATH wrapper (maki/default.nix).
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
