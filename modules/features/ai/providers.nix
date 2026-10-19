# Canonical provider specs for maki's providers.toml. Injected as a single
# `aiProviders` attrset so consumers never import individual providers.
#
# Models are authored via mkModel into maki's providers.toml model shape (see
# modules/features/ai/maki/default.nix).
{ lib, ... }:
let
  ports = import ../../ports.nix;
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
    # Windows are the upstream caps: deepseek serves its full 1M context, qwen
    # its 262K. Both report vision in the /v1/models capabilities, and maki only
    # learns that from this flag.
    makiModels = map mkModel [
      {
        id = "deepseek-v4.1-flash";
        context = 1048576;
        output = 393216;
        vision = true;
        prompt = 0.15;
        completion = 0.60;
        cacheRead = 0.02;
      }
      {
        id = "qwen-3.8-27b";
        context = 262144;
        output = 131072;
        vision = true;
        prompt = 0.45;
        completion = 3.20;
        cacheRead = 0.25;
      }
    ];
  };

  # ── Smortress ─────────────────────────────────────────────────────────────
  # Reached on loopback through the Cloudflare Tunnel; no auth needed.
  # models.qwen38 feeds the dotfiles default model in options.nix.
  qwen38Model = mkModel {
    id = "qwen3.8-27b";
    context = 200192;
    output = 200192;
    prompt = 0.0;
    completion = 0.0;
  };

  # llama.cpp's loopback port: the single source the NixOS listener
  # (modules/nixos/llm.nix) and the tunnel ingress (modules/nixos/web-proxy.nix,
  # from the host's dotfiles.webProxy.services) both read, alongside the client
  # base URL built from it below.
  llmPort = ports.llm;

  smortress = {
    providerId = "smortress";
    models.qwen38 = qwen38Model;
    # Always loopback: on the server llama.cpp is local; on clients a
    # `cloudflared access tcp` forward (modules/features/cloudflared.nix) binds
    # the same port. No DNS to fall through to, so nothing can leak to a
    # look-alike host.
    port = llmPort;
    baseUrl = "http://127.0.0.1:${toString llmPort}/v1";
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
